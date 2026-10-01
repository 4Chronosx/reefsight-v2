import 'package:flutter/material.dart';

import '../services/app_database.dart';
import '../services/device_health_monitor.dart';
import '../services/device_info.dart';
import '../widgets/glove_button.dart';
import '../widgets/ready_to_dive_card.dart';
import '../widgets/section_card.dart';
import 'live_transect_screen.dart';

/// The field team's tapes are 50-100 m (2026-09-28); kept as one `const`
/// list per the sub-plan so the presets are trivial to change.
const kTapeLengthPresetsMeters = [50, 75, 100];

/// Sub-plan 6 (ui-ux-overhaul), step 5: restyle of sub-plan 5's
/// `TransectSetupScreen` -- grouped `SectionCard`s, tape-length quick-pick
/// chips, a non-blocking out-of-range hint, and site/observer prefilled from
/// the most recent session. Still collects only what this project's data
/// model uses: the physical tape length (density denominator, per
/// `ReefSight_Specification.md`'s "Density, positioning, and sync") plus
/// site/observer metadata -- v1's GPS start/end-point pickers stay dropped.
class TransectSetupScreen extends StatefulWidget {
  const TransectSetupScreen({
    super.key,
    this.openDatabase = openAppDatabase,
    this.storageInfo = const PlatformDeviceInfo(),
    this.batteryInfo = const BatteryPlusInfo(),
    this.thermalInfo = const PlatformDeviceInfo(),
  });

  /// Injectable so widget tests can substitute an in-memory DB instead of
  /// `path_provider` (no platform channel under `flutter test`).
  final DatabaseOpener openDatabase;

  /// Sub-plan 13: the "Ready to dive" checks. Injectable so widget tests can
  /// use fakes -- the real ones are platform channels.
  final StorageInfo storageInfo;
  final BatteryInfo batteryInfo;
  final ThermalInfo thermalInfo;

  @override
  State<TransectSetupScreen> createState() => _TransectSetupScreenState();
}

class _TransectSetupScreenState extends State<TransectSetupScreen> {
  final _tapeLengthController = TextEditingController(text: '50');
  final _siteController = TextEditingController();
  final _observerController = TextEditingController();
  late final DeviceHealthMonitor _deviceHealth;

  @override
  void initState() {
    super.initState();
    _prefillFromLastSession();
    // Battery level and free storage don't stream, so re-read them while
    // the diver sits on this screen (e.g. after plugging in).
    _deviceHealth = DeviceHealthMonitor(
      storage: widget.storageInfo,
      battery: widget.batteryInfo,
      thermal: widget.thermalInfo,
      pollInterval: const Duration(seconds: 30),
    )..start();
  }

  /// Prefill is a convenience, not a requirement (sub-plan step 5: "avoids
  /// adding a preferences dependency") -- a DB read failure here shouldn't
  /// block filling the form manually, so it's caught and dropped rather than
  /// surfaced as an error.
  Future<void> _prefillFromLastSession() async {
    try {
      final db = await widget.openDatabase();
      try {
        final sessions = await db.listSessions();
        if (sessions.isEmpty || !mounted) return;
        final last = sessions.first.session;
        setState(() {
          _siteController.text = last.siteName ?? '';
          _observerController.text = last.observerName ?? '';
        });
      } finally {
        await db.close();
      }
    } catch (_) {
      // Ignored -- see doc comment above.
    }
  }

  double? get _parsedTapeLength => double.tryParse(_tapeLengthController.text);

  bool get _isValid {
    final parsed = _parsedTapeLength;
    return parsed != null && parsed > 0;
  }

  /// Non-blocking (sub-plan step 5): a length outside the field team's usual
  /// 50-100 m tapes gets a hint, never a disabled Start button. Requires
  /// `parsed > 0` (not just `_isValid`'s exact check, spelled out again here
  /// to keep this getter self-contained) so this can never be true at the
  /// same time as `_isValid` is false -- `InputDecoration.errorText` and
  /// `helperText` both non-null at once is a real (not just cosmetic) bug:
  /// a blank/zero/negative entry must show the "enter a positive number"
  /// error, not layer an "outside 50-100 m" hint on top of it.
  bool get _outsideUsualRange {
    final parsed = _parsedTapeLength;
    return parsed != null && parsed > 0 && (parsed < 50 || parsed > 100);
  }

  @override
  void dispose() {
    _deviceHealth.dispose();
    _tapeLengthController.dispose();
    _siteController.dispose();
    _observerController.dispose();
    super.dispose();
  }

  void _startTransect() {
    if (!_isValid) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveTransectScreen(
          tapeLengthMeters: _parsedTapeLength!,
          siteName:
              _siteController.text.trim().isEmpty ? null : _siteController.text.trim(),
          observerName: _observerController.text.trim().isEmpty
              ? null
              : _observerController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transect setup')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              icon: Icons.straighten_rounded,
              title: 'Transect',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter the physical marked transect tape length -- this '
                    'is the density denominator, not a GPS-derived distance.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in kTapeLengthPresetsMeters)
                        ChoiceChip(
                          label: Text('$preset m'),
                          selected: _tapeLengthController.text == preset.toString(),
                          onSelected: (_) => setState(
                            () => _tapeLengthController.text = preset.toString(),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tapeLengthController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 20),
                    decoration: InputDecoration(
                      labelText: 'Tape length (meters)',
                      errorText: _isValid ? null : 'Enter a positive number',
                      helperText: _outsideUsualRange
                          ? 'Outside the usual 50-100 m range. Double-check the tape length.'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.badge_outlined,
              title: 'Survey details',
              child: Column(
                children: [
                  TextField(
                    controller: _siteController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Site name (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _observerController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Observer name (optional)'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<DeviceHealth?>(
              valueListenable: _deviceHealth.health,
              builder: (context, health, _) => ReadyToDiveCard(health: health),
            ),
            const SizedBox(height: 16),
            const SectionCard(
              icon: Icons.checklist_rounded,
              title: 'Before you dive',
              child: Text(
                '• Camera housing sealed\n'
                '• Transect tape laid out\n'
                '• Lighting checked\n'
                '• Phone held in landscape orientation',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
            const SizedBox(height: 24),
            GloveButton(
              label: 'Start Transect',
              onPressed: _isValid ? _startTransect : null,
            ),
          ],
        ),
      ),
    );
  }
}
