import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_health_monitor.dart';
import 'package:reefsight_mobile/services/device_info.dart';

// Sub-plan 13 steps 1 and 3: the monitor behind Setup's "Ready to dive"
// card and Live's HUD badge, driven entirely by fakes -- the real
// providers are platform channels with nothing behind them under
// `flutter test`.

class _FakeStorage implements StorageInfo {
  int? bytes = 64 * 1000 * 1000 * 1000;
  bool fail = false;
  int reads = 0;

  @override
  Future<int?> freeBytes() async {
    reads++;
    if (fail) throw StateError('storage failed');
    return bytes;
  }
}

class _FakeBattery implements BatteryInfo {
  BatteryReading reading = const BatteryReading(percent: 80, charging: false);
  bool fail = false;
  final changesController = StreamController<void>.broadcast();

  @override
  Future<BatteryReading?> read() async {
    if (fail) throw StateError('battery failed');
    return reading;
  }

  @override
  Stream<void> get changes => changesController.stream;
}

class _FakeThermal implements ThermalInfo {
  ThermalLevel? level = ThermalLevel.nominal;
  int reads = 0;
  final changesController = StreamController<ThermalLevel>.broadcast();

  @override
  Future<ThermalLevel?> current() async {
    reads++;
    return level;
  }

  @override
  Stream<ThermalLevel> get changes => changesController.stream;
}

void main() {
  late _FakeStorage storage;
  late _FakeBattery battery;
  late _FakeThermal thermal;
  late List<(ThermalLevel, int)> thermalChanges;

  DeviceHealthMonitor monitor({Duration poll = const Duration(seconds: 60)}) =>
      DeviceHealthMonitor(
        storage: storage,
        battery: battery,
        thermal: thermal,
        pollInterval: poll,
        onThermalChange: (peak, rises) => thermalChanges.add((peak, rises)),
      );

  setUp(() {
    storage = _FakeStorage();
    battery = _FakeBattery();
    thermal = _FakeThermal();
    thermalChanges = [];
  });

  test('has no snapshot before start, then one check per provider', () async {
    final m = monitor();
    addTearDown(m.dispose);
    expect(m.health.value, isNull);

    battery.reading = const BatteryReading(percent: 30, charging: false);
    await m.start();

    final health = m.health.value!;
    expect(health.storage.status, CheckStatus.ok);
    expect(health.battery.status, CheckStatus.warn);
    expect(health.thermal.status, CheckStatus.ok);
    expect(health.thermalLevel, ThermalLevel.nominal);
  });

  test('a failing provider reads as unavailable; the others still read', () async {
    storage.fail = true;
    battery.fail = true;
    final m = monitor();
    addTearDown(m.dispose);

    await m.start();

    final health = m.health.value!;
    expect(health.storage.status, CheckStatus.unavailable);
    expect(health.battery.status, CheckStatus.unavailable);
    expect(health.thermal.status, CheckStatus.ok);
  });

  test('the first thermal reading sets the peak without counting a rise', () async {
    thermal.level = ThermalLevel.fair;
    final m = monitor();
    addTearDown(m.dispose);

    await m.start();

    expect(m.thermalPeak, ThermalLevel.fair);
    expect(m.thermalRises, 0);
    expect(thermalChanges, [(ThermalLevel.fair, 0)]);
  });

  test('every step up counts as a rise, including after cooling down', () async {
    final m = monitor();
    addTearDown(m.dispose);
    await m.start();

    for (final level in [
      ThermalLevel.serious, // rise 1
      ThermalLevel.fair, // cooling: no rise
      ThermalLevel.serious, // rise 2
      ThermalLevel.serious, // same: nothing
      ThermalLevel.critical, // rise 3
    ]) {
      thermal.changesController.add(level);
      await pumpEventQueue();
    }

    expect(m.thermalPeak, ThermalLevel.critical);
    expect(m.thermalRises, 3);
    expect(m.health.value!.thermalLevel, ThermalLevel.critical);
    expect(thermalChanges, [
      (ThermalLevel.nominal, 0),
      (ThermalLevel.serious, 1),
      (ThermalLevel.serious, 2),
      (ThermalLevel.critical, 3),
    ]);
  });

  test('an unknown thermal state is unavailable and never sets a peak', () async {
    thermal.level = null;
    final m = monitor();
    addTearDown(m.dispose);

    await m.start();

    expect(m.health.value!.thermal.status, CheckStatus.unavailable);
    expect(m.thermalPeak, isNull);
    expect(thermalChanges, isEmpty);
  });

  test('a battery state change re-reads the battery', () async {
    final m = monitor();
    addTearDown(m.dispose);
    await m.start();

    battery.reading = const BatteryReading(percent: 15, charging: true);
    battery.changesController.add(null);
    await pumpEventQueue();

    expect(m.health.value!.battery.reason, 'Charging (15%)');
  });

  test('re-reads storage and battery every poll interval, until disposed',
      () async {
    final m = monitor(poll: const Duration(milliseconds: 20));
    await m.start();
    expect(storage.reads, 1);

    storage.bytes = 1000;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(storage.reads, greaterThanOrEqualTo(2));
    expect(m.health.value!.storage.status, CheckStatus.critical);

    m.dispose();
    final readsAtDispose = storage.reads;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(storage.reads, readsAtDispose);
  });

  test('after the first read, thermal follows only the stream, never the poll',
      () async {
    final m = monitor(poll: const Duration(milliseconds: 20));
    addTearDown(m.dispose);
    await m.start();

    thermal.changesController.add(ThermalLevel.serious);
    await pumpEventQueue();
    // A poll re-reading this stale value would count a cool-down, and the
    // next stream event a rise that never happened.
    thermal.level = ThermalLevel.nominal;
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(thermal.reads, 1);
    expect(m.health.value!.thermalLevel, ThermalLevel.serious);
    expect(m.thermalRises, 1);
  });

  test('the first snapshot already includes the thermal reading', () async {
    final m = monitor();
    addTearDown(m.dispose);
    final snapshots = <DeviceHealth?>[];
    m.health.addListener(() => snapshots.add(m.health.value));

    await m.start();

    expect(snapshots, hasLength(1));
    expect(snapshots.single!.thermal.status, CheckStatus.ok);
  });

  test('dispose stops listening, and nothing publishes afterwards', () async {
    final m = monitor();
    await m.start();
    expect(thermal.changesController.hasListener, isTrue);

    m.dispose();

    expect(thermal.changesController.hasListener, isFalse);
    expect(battery.changesController.hasListener, isFalse);
    // A refresh still in flight when the screen closes must not throw on
    // the disposed notifier.
    await m.refresh();
  });

  group('DeviceHealth.needsAttention', () {
    DeviceHealth health({
      CheckStatus storageStatus = CheckStatus.ok,
      CheckStatus batteryStatus = CheckStatus.ok,
      ThermalLevel? level = ThermalLevel.nominal,
    }) =>
        DeviceHealth(
          storage: CheckResult(storageStatus, ''),
          battery: CheckResult(batteryStatus, ''),
          thermal: thermalCheck(level),
          thermalLevel: level,
        );

    test('is false when everything is ok, warned or unknown', () {
      expect(health().needsAttention, isFalse);
      expect(health(batteryStatus: CheckStatus.warn).needsAttention, isFalse);
      expect(health(storageStatus: CheckStatus.warn).needsAttention, isFalse);
      expect(health(level: ThermalLevel.fair).needsAttention, isFalse);
      expect(health(level: null).needsAttention, isFalse);
    });

    test('is true from serious heat, or red battery or storage', () {
      expect(health(level: ThermalLevel.serious).needsAttention, isTrue);
      expect(health(level: ThermalLevel.critical).needsAttention, isTrue);
      expect(health(batteryStatus: CheckStatus.critical).needsAttention, isTrue);
      expect(health(storageStatus: CheckStatus.critical).needsAttention, isTrue);
    });
  });
}
