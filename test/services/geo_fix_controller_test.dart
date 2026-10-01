import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/geo_fix.dart';
import 'package:reefsight_mobile/services/geo_fix_controller.dart';
import 'package:reefsight_mobile/services/location_provider.dart';

import '../support/fake_location.dart';

// Sub-plan 12 steps 3-4: the acquire / retry / manual state behind both
// GPS cards (entry on Setup, exit on Summary), and the "Ready to dive"
// entry-position row derived from it.

GeoFix _manual() => GeoFix(
      lat: 10.3,
      lon: 123.9,
      at: DateTime.utc(2026, 10, 2),
      source: GeoFixSource.manual,
    );

void main() {
  group('GeoFixController', () {
    test('starts idle', () {
      final controller = GeoFixController(FakeLocationProvider.fix());
      addTearDown(controller.dispose);
      expect(controller.value.acquiring, isFalse);
      expect(controller.value.fix, isNull);
      expect(controller.value.failure, isNull);
    });

    test('acquire goes through acquiring to the fix', () async {
      final provider = FakeLocationProvider.fix()..hold = Completer<void>();
      final controller = GeoFixController(provider);
      addTearDown(controller.dispose);

      final done = controller.acquire();
      expect(controller.value.acquiring, isTrue);

      provider.hold!.complete();
      await done;
      expect(controller.value.acquiring, isFalse);
      expect(controller.value.fix, testGpsFix());
      expect(controller.value.failure, isNull);
    });

    test('a failed acquire keeps the failure reason', () async {
      final controller =
          GeoFixController(FakeLocationProvider.failure(LocationFailureKind.servicesOff));
      addTearDown(controller.dispose);

      await controller.acquire();
      expect(controller.value.fix, isNull);
      expect(controller.value.failure!.kind, LocationFailureKind.servicesOff);
    });

    test('a failed retry keeps the earlier fix', () async {
      final controller = GeoFixController(
        FakeLocationProvider([
          LocationFix(testGpsFix()),
          const LocationFailure(LocationFailureKind.timeout),
        ]),
      );
      addTearDown(controller.dispose);

      await controller.acquire();
      await controller.acquire();
      expect(controller.value.fix, testGpsFix());
      expect(controller.value.failure!.kind, LocationFailureKind.timeout);
    });

    test('a manual fix wins over a GPS result still in flight', () async {
      final provider = FakeLocationProvider.fix()..hold = Completer<void>();
      final controller = GeoFixController(provider);
      addTearDown(controller.dispose);

      final done = controller.acquire();
      controller.setManual(_manual());
      provider.hold!.complete();
      await done;

      expect(controller.value.fix, _manual());
      expect(controller.value.acquiring, isFalse);
    });

    test('a result arriving after dispose is dropped without error', () async {
      final provider = FakeLocationProvider.fix()..hold = Completer<void>();
      final controller = GeoFixController(provider);

      final done = controller.acquire();
      controller.dispose();
      provider.hold!.complete();
      await done; // would throw if it set value on a disposed notifier
    });
  });

  group('entryPositionCheck', () {
    test('null while acquiring with no fix yet', () {
      expect(entryPositionCheck(const GeoFixState(acquiring: true)), isNull);
    });

    test('ok with the fix', () {
      final check = entryPositionCheck(GeoFixState(fix: testGpsFix()))!;
      expect(check.status, CheckStatus.ok);
      expect(check.reason, formatFix(testGpsFix()));
    });

    test('warns, without blocking, when there is no fix', () {
      final check = entryPositionCheck(
        const GeoFixState(failure: LocationFailure(LocationFailureKind.timeout)),
      )!;
      expect(check.status, CheckStatus.warn);
      expect(check.reason, "No entry position — it'll be missing from the report.");
    });
  });
}
