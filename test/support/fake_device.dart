import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_info.dart';

/// Fixed device readings for screens that run sub-plan 13's pre-dive
/// checks. The real providers are platform channels: under `flutter test`
/// `battery_plus` reports a `MissingPluginException` as a test failure, so
/// any test that builds `TransectSetupScreen` passes this instead.
class FakeDevice implements StorageInfo, BatteryInfo, ThermalInfo {
  FakeDevice({
    this.bytes = 64 * 1000 * 1000 * 1000,
    this.battery = const BatteryReading(percent: 80, charging: false),
    this.thermal = ThermalLevel.nominal,
  });

  final int? bytes;
  final BatteryReading? battery;
  final ThermalLevel? thermal;

  @override
  Future<int?> freeBytes() async => bytes;

  @override
  Future<BatteryReading?> read() async => battery;

  @override
  Future<ThermalLevel?> current() async => thermal;

  @override
  Stream<Never> get changes => const Stream.empty();
}
