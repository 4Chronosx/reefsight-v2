import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';

import 'device_checks.dart';

/// The device readings behind sub-plan 13's pre-dive checks, each behind an
/// interface so tests can substitute a fake (same pattern as
/// `screen_awake.dart`). The real implementations may throw on a platform
/// without support; `DeviceHealthMonitor` catches that and shows the check
/// as unavailable.

/// Free space on the volume the recording is written to.
abstract interface class StorageInfo {
  /// Bytes available, or `null` if the platform can't say.
  Future<int?> freeBytes();
}

class BatteryReading {
  const BatteryReading({required this.percent, required this.charging});

  final int percent;

  /// Plugged in: charging or already full.
  final bool charging;
}

abstract interface class BatteryInfo {
  Future<BatteryReading?> read();

  /// Fires when the charging state changes (plugged in, unplugged, full).
  /// Level changes don't fire; `DeviceHealthMonitor` polls for those.
  Stream<void> get changes;
}

abstract interface class ThermalInfo {
  Future<ThermalLevel?> current();

  /// Every thermal state change, as the OS reports it.
  Stream<ThermalLevel> get changes;
}

/// [BatteryInfo] from `battery_plus`.
class BatteryPlusInfo implements BatteryInfo {
  const BatteryPlusInfo();

  static final _battery = Battery();

  @override
  Future<BatteryReading?> read() async {
    final percent = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    return BatteryReading(
      percent: percent,
      charging: state == BatteryState.charging || state == BatteryState.full,
    );
  }

  @override
  Stream<void> get changes => _battery.onBatteryStateChanged;
}

/// [StorageInfo] and [ThermalInfo] from `ios/Runner/AppDelegate.swift`'s
/// `reefsight/device` and `reefsight/thermal` channels: `FileManager`'s
/// `volumeAvailableCapacityForImportantUsage` and
/// `ProcessInfo.thermalState`. iOS only -- elsewhere both read as `null`
/// (unavailable) without touching the channel.
class PlatformDeviceInfo implements StorageInfo, ThermalInfo {
  const PlatformDeviceInfo();

  static const _device = MethodChannel('reefsight/device');
  static const _thermal = EventChannel('reefsight/thermal');

  static bool get _supported => Platform.isIOS;

  @override
  Future<int?> freeBytes() async {
    if (!_supported) return null;
    return _device.invokeMethod<int>('freeBytes');
  }

  @override
  Future<ThermalLevel?> current() async {
    if (!_supported) return null;
    return ThermalLevel.fromRaw(await _device.invokeMethod<int>('thermalState'));
  }

  /// One stream for the whole app. Setup stays mounted under Live, so both
  /// listen at once; separate `receiveBroadcastStream()` calls would each
  /// replace the channel's handler, and Live's cancel would silently end
  /// Setup's subscription.
  static final Stream<ThermalLevel> _changes = _thermal
      .receiveBroadcastStream()
      .map(ThermalLevel.fromRaw)
      .where((level) => level != null)
      .cast<ThermalLevel>();

  @override
  Stream<ThermalLevel> get changes => _supported ? _changes : const Stream.empty();
}
