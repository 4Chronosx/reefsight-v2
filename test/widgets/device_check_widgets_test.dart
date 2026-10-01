import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_health_monitor.dart';
import 'package:reefsight_mobile/widgets/live/device_health_badge.dart';
import 'package:reefsight_mobile/widgets/ready_to_dive_card.dart';

// Sub-plan 13 steps 2-3: the Setup "Ready to dive" card and the Live HUD
// badge, rendered from fixed `DeviceHealth` values.

DeviceHealth _health({
  int? freeBytes = 64 * 1000 * 1000 * 1000,
  int? battery = 80,
  bool charging = false,
  ThermalLevel? thermal = ThermalLevel.nominal,
}) =>
    DeviceHealth(
      storage: storageCheck(freeBytes),
      battery: batteryCheck(battery, charging: charging),
      thermal: thermalCheck(thermal),
      thermalLevel: thermal,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder _statusIcon(String label) => find.byKey(ValueKey('device-check-$label'));

void main() {
  group('ReadyToDiveCard', () {
    testWidgets('shows "Checking…" for every device check before the first reading',
        (tester) async {
      await tester.pumpWidget(_wrap(const ReadyToDiveCard(health: null)));

      expect(find.text('Checking…'), findsNWidgets(3));
    });

    testWidgets('lists storage, battery, heat and entry position with reasons',
        (tester) async {
      await tester.pumpWidget(_wrap(ReadyToDiveCard(health: _health(battery: 30))));

      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Battery'), findsOneWidget);
      expect(find.text('Heat'), findsOneWidget);
      expect(find.text('Entry position'), findsOneWidget);
      expect(find.text('64.0 GB free'), findsOneWidget);
      expect(find.text('30%, may not last a long transect.'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
    });

    testWidgets('each row shows its own status', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ReadyToDiveCard(
            health: _health(
              freeBytes: 1000,
              battery: 30,
              thermal: null,
            ),
          ),
        ),
      );

      expect(
        tester.widget<Icon>(_statusIcon('Storage')).icon,
        statusIcon(CheckStatus.critical),
      );
      expect(
        tester.widget<Icon>(_statusIcon('Battery')).icon,
        statusIcon(CheckStatus.warn),
      );
      expect(
        tester.widget<Icon>(_statusIcon('Heat')).icon,
        statusIcon(CheckStatus.unavailable),
      );
    });
  });

  group('DeviceHealthBadge', () {
    testWidgets('is hidden while nothing needs attention', (tester) async {
      await tester.pumpWidget(_wrap(DeviceHealthBadge(health: _health(battery: 30))));
      expect(find.byType(Text), findsNothing);

      await tester.pumpWidget(_wrap(const DeviceHealthBadge(health: null)));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('follows the thermal state as it changes', (tester) async {
      final health = ValueNotifier<DeviceHealth?>(_health());
      addTearDown(health.dispose);
      await tester.pumpWidget(
        _wrap(
          ValueListenableBuilder<DeviceHealth?>(
            valueListenable: health,
            builder: (context, value, _) => DeviceHealthBadge(health: value),
          ),
        ),
      );
      expect(find.textContaining('hot'), findsNothing);

      health.value = _health(thermal: ThermalLevel.serious);
      await tester.pump();
      expect(find.text('Phone hot'), findsOneWidget);

      health.value = _health(thermal: ThermalLevel.critical);
      await tester.pump();
      expect(find.text('Phone very hot'), findsOneWidget);

      health.value = _health(thermal: ThermalLevel.fair);
      await tester.pump();
      expect(find.textContaining('hot'), findsNothing);
    });

    testWidgets('names every red item at once', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DeviceHealthBadge(
            health: _health(
              freeBytes: 1000,
              battery: 10,
              thermal: ThermalLevel.serious,
            ),
          ),
        ),
      );

      expect(find.text('Phone hot · Battery low · Storage low'), findsOneWidget);
    });

    testWidgets('a charging phone at low battery is not flagged', (tester) async {
      await tester.pumpWidget(
        _wrap(DeviceHealthBadge(health: _health(battery: 10, charging: true))),
      );
      expect(find.byType(Text), findsNothing);
    });
  });
}
