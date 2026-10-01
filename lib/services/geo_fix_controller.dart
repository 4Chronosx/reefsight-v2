import 'package:flutter/foundation.dart';

import 'device_checks.dart';
import 'geo_fix.dart';
import 'location_provider.dart';

/// What a GPS card shows: the current fix (GPS or manual), whether an
/// acquisition is running, and the last failure. A failed retry keeps the
/// earlier [fix] -- a worse attempt never throws away a good one.
@immutable
class GeoFixState {
  const GeoFixState({this.fix, this.acquiring = false, this.failure});

  final GeoFix? fix;
  final bool acquiring;
  final LocationFailure? failure;

  /// Nothing tried yet: no fix, no failure, not acquiring.
  bool get idle => fix == null && !acquiring && failure == null;
}

/// Sub-plan 12 steps 3-4: acquire / retry / manual entry for one fix,
/// shared by Setup's entry card and Summary's exit card. A
/// [ValueNotifier], like `DeviceHealthMonitor.health`, so the card and the
/// "Ready to dive" row read the same state.
class GeoFixController extends ValueNotifier<GeoFixState> {
  GeoFixController(this._provider) : super(const GeoFixState());

  final LocationProvider _provider;

  /// Bumped by every [acquire] and [setManual], so a GPS result that
  /// arrives after a newer action is dropped instead of overwriting it.
  int _generation = 0;
  bool _disposed = false;

  Future<void> acquire() async {
    final generation = ++_generation;
    value = GeoFixState(fix: value.fix, acquiring: true);
    final result = await _provider.current();
    if (_disposed || generation != _generation) return;
    value = switch (result) {
      LocationFix(:final fix) => GeoFixState(fix: fix),
      LocationFailure() => GeoFixState(fix: value.fix, failure: result),
    };
  }

  /// A typed-in fix (decision 4: manual entry is always available). Cancels
  /// any acquisition still running.
  void setManual(GeoFix fix) {
    _generation++;
    value = GeoFixState(fix: fix);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The "Ready to dive" card's entry-position row (sub-plan 13 step 2,
/// filled in by sub-plan 12). `null` ("Checking…") while the first fix is
/// still being acquired. A missing fix warns but never blocks Start
/// (decision 5).
CheckResult? entryPositionCheck(GeoFixState state) {
  final fix = state.fix;
  if (fix != null) return CheckResult(CheckStatus.ok, formatFix(fix));
  if (state.acquiring) return null;
  return const CheckResult(
    CheckStatus.warn,
    "No entry position — it'll be missing from the report.",
  );
}
