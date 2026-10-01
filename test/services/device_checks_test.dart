import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/device_checks.dart';

// Sub-plan 13 (pre-dive checks), "Tests": thresholds -> status for each
// provider value, including the boundaries and "charging".

void main() {
  const gb = 1000 * 1000 * 1000;
  const estimate = DevicePolicy.estimatedTransectBytes;

  group('storageCheck', () {
    test('below 1x the estimated transect size is critical', () {
      expect(storageCheck(estimate - 1).status, CheckStatus.critical);
      expect(storageCheck(0).status, CheckStatus.critical);
    });

    test('exactly 1x, and anything below 2x, is a warning', () {
      expect(storageCheck(estimate).status, CheckStatus.warn);
      expect(storageCheck(2 * estimate - 1).status, CheckStatus.warn);
    });

    test('2x or more is ok', () {
      expect(storageCheck(2 * estimate).status, CheckStatus.ok);
      expect(storageCheck(64 * gb).status, CheckStatus.ok);
    });

    test('unknown free space is unavailable, not ok', () {
      expect(storageCheck(null).status, CheckStatus.unavailable);
    });

    test('the reason states the free space in GB', () {
      expect(storageCheck(12400 * 1000 * 1000).reason, contains('12.4 GB free'));
    });
  });

  group('batteryCheck', () {
    test('below 20% is critical', () {
      expect(batteryCheck(19, charging: false).status, CheckStatus.critical);
      expect(batteryCheck(0, charging: false).status, CheckStatus.critical);
    });

    test('20% up to 39% is a warning', () {
      expect(batteryCheck(20, charging: false).status, CheckStatus.warn);
      expect(batteryCheck(39, charging: false).status, CheckStatus.warn);
    });

    test('40% and above is ok', () {
      expect(batteryCheck(40, charging: false).status, CheckStatus.ok);
      expect(batteryCheck(100, charging: false).status, CheckStatus.ok);
    });

    test('charging is ok at any level', () {
      final check = batteryCheck(5, charging: true);
      expect(check.status, CheckStatus.ok);
      expect(check.reason, contains('Charging'));
      expect(check.reason, contains('5%'));
    });

    test('unknown level is unavailable', () {
      expect(batteryCheck(null, charging: false).status, CheckStatus.unavailable);
      expect(batteryCheck(null, charging: true).status, CheckStatus.unavailable);
    });
  });

  group('thermalCheck', () {
    test('nominal and fair are ok', () {
      expect(thermalCheck(ThermalLevel.nominal).status, CheckStatus.ok);
      expect(thermalCheck(ThermalLevel.fair).status, CheckStatus.ok);
    });

    test('serious is a warning, critical is critical', () {
      expect(thermalCheck(ThermalLevel.serious).status, CheckStatus.warn);
      expect(thermalCheck(ThermalLevel.critical).status, CheckStatus.critical);
    });

    test('unknown state is unavailable', () {
      expect(thermalCheck(null).status, CheckStatus.unavailable);
    });
  });

  group('ThermalLevel.fromRaw', () {
    test("maps iOS ProcessInfo.ThermalState raw values in order", () {
      expect(ThermalLevel.fromRaw(0), ThermalLevel.nominal);
      expect(ThermalLevel.fromRaw(1), ThermalLevel.fair);
      expect(ThermalLevel.fromRaw(2), ThermalLevel.serious);
      expect(ThermalLevel.fromRaw(3), ThermalLevel.critical);
    });

    test('anything else is null', () {
      expect(ThermalLevel.fromRaw(4), isNull);
      expect(ThermalLevel.fromRaw(-1), isNull);
      expect(ThermalLevel.fromRaw('2'), isNull);
      expect(ThermalLevel.fromRaw(null), isNull);
    });
  });
}
