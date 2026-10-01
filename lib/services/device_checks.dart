/// Pre-dive device checks -- sub-plan 13
/// (`mobile/sub-plans/13-pre-dive-checks.md`). Once the phone is sealed in
/// the housing, a full disk, a flat battery or heat throttling can't be
/// fixed, so Setup and Live show them up front.
///
/// Decision 1: warn, never block. These are statuses with a reason, never
/// a reason to disable Start.
library;

/// Thresholds for the pre-dive checks (sub-plan 13 decision 2). One place
/// for them, like `ClassificationPolicy`. Starting values from the
/// sub-plan, not tuned numbers.
abstract final class DevicePolicy {
  /// One transect's recording, in bytes. The Spec's Cloud sync estimate is
  /// ~0.6-1.2 GB; this takes the top of it. Decision 3: replace with
  /// measured bytes per minute x expected minutes after sub-plan 09's
  /// device session, and record the measurement in the sub-plan.
  static const int estimatedTransectBytes = 1200 * 1000 * 1000;

  /// Storage is critical below this many estimated transects of free
  /// space, and a warning below [storageWarnTransects].
  static const int storageCriticalTransects = 1;
  static const int storageWarnTransects = 2;

  /// Battery percentages: critical below the first, a warning below the
  /// second. Charging is always ok.
  static const int batteryCriticalPercent = 20;
  static const int batteryWarnPercent = 40;
}

/// Green, amber, red -- or grey when the value couldn't be read (no
/// platform support, a failed platform call). [unavailable] is never shown
/// as ok: an unknown value isn't a passed check.
enum CheckStatus { ok, warn, critical, unavailable }

/// iOS `ProcessInfo.ThermalState`, in the same order as its raw values, so
/// [index] comparisons mean "hotter than".
enum ThermalLevel {
  nominal,
  fair,
  serious,
  critical;

  /// The raw value the platform channel sends (`thermalState.rawValue`),
  /// or `null` for anything that isn't one.
  static ThermalLevel? fromRaw(Object? raw) =>
      raw is int && raw >= 0 && raw < values.length ? values[raw] : null;
}

/// One check's status plus the one line of reason the Setup card shows.
class CheckResult {
  const CheckResult(this.status, this.reason);

  final CheckStatus status;
  final String reason;
}

String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

CheckResult storageCheck(int? freeBytes) {
  if (freeBytes == null) {
    return const CheckResult(CheckStatus.unavailable, "Couldn't read free storage");
  }
  const transect = DevicePolicy.estimatedTransectBytes;
  final free = '${_gb(freeBytes)} free';
  if (freeBytes < DevicePolicy.storageCriticalTransects * transect) {
    return CheckResult(
      CheckStatus.critical,
      '$free, less than one transect (~${_gb(transect)}). Recording may stop.',
    );
  }
  if (freeBytes < DevicePolicy.storageWarnTransects * transect) {
    return CheckResult(
      CheckStatus.warn,
      '$free, room for about one transect (~${_gb(transect)}).',
    );
  }
  return CheckResult(CheckStatus.ok, free);
}

CheckResult batteryCheck(int? percent, {required bool charging}) {
  if (percent == null) {
    return const CheckResult(CheckStatus.unavailable, "Couldn't read the battery");
  }
  if (charging) return CheckResult(CheckStatus.ok, 'Charging ($percent%)');
  if (percent < DevicePolicy.batteryCriticalPercent) {
    return CheckResult(CheckStatus.critical, '$percent%, may not last the transect.');
  }
  if (percent < DevicePolicy.batteryWarnPercent) {
    return CheckResult(CheckStatus.warn, '$percent%, may not last a long transect.');
  }
  return CheckResult(CheckStatus.ok, '$percent%');
}

CheckResult thermalCheck(ThermalLevel? level) => switch (level) {
      null => const CheckResult(CheckStatus.unavailable, "Couldn't read the temperature"),
      ThermalLevel.nominal => const CheckResult(CheckStatus.ok, 'Normal'),
      ThermalLevel.fair => const CheckResult(CheckStatus.ok, 'Warm'),
      ThermalLevel.serious => const CheckResult(
          CheckStatus.warn,
          'Hot. The phone will slow down; keep it in the shade.',
        ),
      ThermalLevel.critical => const CheckResult(
          CheckStatus.critical,
          'Very hot. Let it cool before sealing the housing.',
        ),
    };
