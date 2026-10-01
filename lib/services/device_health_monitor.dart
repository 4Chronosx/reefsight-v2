import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_checks.dart';
import 'device_info.dart';

/// One reading of all three pre-dive checks (sub-plan 13).
class DeviceHealth {
  const DeviceHealth({
    required this.storage,
    required this.battery,
    required this.thermal,
    required this.thermalLevel,
  });

  final CheckResult storage;
  final CheckResult battery;
  final CheckResult thermal;

  /// The raw thermal state behind [thermal]; `null` when unavailable.
  final ThermalLevel? thermalLevel;

  /// Sub-plan 13 step 3: whether Live shows its HUD badge -- heat at
  /// `serious` or worse, or battery or storage red. Amber battery and
  /// storage were already shown on Setup and don't need the diver's
  /// attention mid-transect.
  bool get needsAttention =>
      (thermalLevel?.index ?? -1) >= ThermalLevel.serious.index ||
      battery.status == CheckStatus.critical ||
      storage.status == CheckStatus.critical;
}

/// Reports the session's new thermal peak and rise count, whenever either
/// changes.
typedef ThermalChangeCallback = void Function(ThermalLevel peak, int rises);

/// Reads storage, battery and heat, keeps [health] current, and tracks the
/// thermal peak and rises for the session -- sub-plan 13 steps 2-3. Used by
/// Setup's "Ready to dive" card and Live's HUD badge.
///
/// Thermal and charging-state changes arrive as streams; battery level and
/// free storage don't, so they're re-read every [pollInterval]. A provider
/// that throws reads as unavailable and is logged -- a check must never
/// break the screen it's on.
class DeviceHealthMonitor {
  DeviceHealthMonitor({
    required StorageInfo storage,
    required BatteryInfo battery,
    required ThermalInfo thermal,
    this.pollInterval = const Duration(seconds: 60),
    this.onThermalChange,
  })  : _storage = storage,
        _battery = battery,
        _thermal = thermal;

  final StorageInfo _storage;
  final BatteryInfo _battery;
  final ThermalInfo _thermal;
  final Duration pollInterval;
  final ThermalChangeCallback? onThermalChange;

  /// `null` until the first reading completes.
  ValueListenable<DeviceHealth?> get health => _health;
  final _health = ValueNotifier<DeviceHealth?>(null);

  /// The hottest state seen since [start]; `null` if it was never readable.
  ThermalLevel? get thermalPeak => _peak;
  ThermalLevel? _peak;

  /// How many times the state stepped up (sub-plan 13 step 3). Every step
  /// counts, so heating, cooling, then heating again is two rises.
  int get thermalRises => _rises;
  int _rises = 0;

  ThermalLevel? _lastThermal;
  CheckResult? _storageCheck;
  CheckResult? _batteryCheck;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _timer;
  bool _disposed = false;

  /// Reads everything once, then follows the streams and polls.
  ///
  /// Thermal is read once, before subscribing, and from then on only
  /// follows the stream: re-reading it on the poll could land a stale value
  /// after a newer stream event and count a rise that never happened.
  Future<void> start() async {
    _subscriptions.add(
      _battery.changes.listen((_) => _refreshBattery(), onError: _logStreamError),
    );
    _timer = Timer.periodic(pollInterval, (_) => refresh());
    final thermal = _read('thermal', _thermal.current);
    await _readStorageAndBattery();
    // Publishes the first snapshot, with all three checks in it.
    _onThermal(await thermal);
    if (_disposed) return;
    _subscriptions.add(_thermal.changes.listen(_onThermal, onError: _logStreamError));
  }

  /// Re-reads storage and battery, which don't stream changes, and
  /// publishes a snapshot.
  Future<void> refresh() async {
    await _readStorageAndBattery();
    _publish();
  }

  Future<void> _readStorageAndBattery() async {
    final results = await Future.wait<Object?>([
      _read('storage', _storage.freeBytes),
      _read('battery', _battery.read),
    ]);
    if (_disposed) return;
    final reading = results[1] as BatteryReading?;
    _storageCheck = storageCheck(results[0] as int?);
    _batteryCheck = batteryCheck(reading?.percent, charging: reading?.charging ?? false);
  }

  Future<void> _refreshBattery() async {
    final reading = await _read('battery', _battery.read);
    if (_disposed) return;
    _batteryCheck = batteryCheck(reading?.percent, charging: reading?.charging ?? false);
    _publish();
  }

  void _onThermal(ThermalLevel? level) {
    if (_disposed) return;
    if (level != null) {
      final last = _lastThermal;
      final peak = _peak;
      final rose = last != null && level.index > last.index;
      if (rose) _rises++;
      if (peak == null || level.index > peak.index) _peak = level;
      if (rose || peak != _peak) onThermalChange?.call(_peak!, _rises);
    }
    _lastThermal = level;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    _health.value = DeviceHealth(
      storage: _storageCheck ?? storageCheck(null),
      battery: _batteryCheck ?? batteryCheck(null, charging: false),
      thermal: thermalCheck(_lastThermal),
      thermalLevel: _lastThermal,
    );
  }

  Future<T?> _read<T>(String what, Future<T?> Function() read) async {
    try {
      return await read();
    } catch (error) {
      debugPrint('ReefSight: failed to read $what for pre-dive checks: $error');
      return null;
    }
  }

  void _logStreamError(Object error) {
    debugPrint('ReefSight: device check stream error: $error');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _health.dispose();
  }
}
