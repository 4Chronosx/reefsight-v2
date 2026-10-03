import 'package:flutter/material.dart';

import '../services/app_database.dart';
import '../services/app_settings.dart';
import '../services/classification_policy.dart';
import '../services/crop_geometry.dart';
import '../services/model_assets.dart';
import '../widgets/section_card.dart';

/// Sub-plan 6 (ui-ux-overhaul), step 7: Settings/About -- a diagnostics
/// toggle for Live's debug overlay, an About section disclosing which model
/// assets are bundled and that they're interim (mobile `CLAUDE.md`'s "Models
/// are interim, not final" -- honest disclosure to LGU users and the panel),
/// and a Data section with storage location/session count. No clear-all
/// action: a survey is deleted one at a time from Surveys, after a confirm
/// (`docs/survey-deletion.md`).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.openDatabase = openAppDatabase});

  /// Injectable so widget tests can substitute an in-memory DB instead of
  /// `path_provider` (no platform channel under `flutter test`).
  final DatabaseOpener openDatabase;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Future<int> _sessionCount = _loadSessionCount();

  Future<int> _loadSessionCount() async {
    final db = await widget.openDatabase();
    try {
      final sessions = await db.listSessions();
      return sessions.length;
    } finally {
      await db.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            icon: Icons.bug_report_outlined,
            title: 'Diagnostics',
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.instance.showDiagnostics,
                  builder: (context, showDiagnostics, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show diagnostics on Live'),
                    subtitle: const Text(
                      'Per-track debug overlay (segmentation time, track IDs, '
                      'tracker update rate) for field debugging.',
                    ),
                    value: showDiagnostics,
                    onChanged: (value) =>
                        AppSettings.instance.showDiagnostics.value = value,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.instance.legacyLiveLoop,
                  builder: (context, legacyLiveLoop, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Legacy live loop (baseline)'),
                    subtitle: const Text(
                      'Measurement only: the old loop that skips frames '
                      'while classifying. Applies from the next transect. '
                      'Leave off for real surveys.',
                    ),
                    value: legacyLiveLoop,
                    onChanged: (value) =>
                        AppSettings.instance.legacyLiveLoop.value = value,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: AppSettings.instance.cameraMotionCompensation,
                  builder: (context, cmc, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Camera motion compensation'),
                    subtitle: const Text(
                      'Corrects tracks for the camera moving between frames. '
                      'Off: tracker ignores camera motion, as before. '
                      'Applies from the next transect.',
                    ),
                    value: cmc,
                    onChanged: (value) =>
                        AppSettings.instance.cameraMotionCompensation.value = value,
                  ),
                ),
                ValueListenableBuilder<CropStyle>(
                  valueListenable: AppSettings.instance.cropStyle,
                  builder: (context, cropStyle, _) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Classifier crop'),
                    subtitle: const Text(
                      'Comparison only. "Inside mask" is the spec default. '
                      'Applies from the next transect.',
                    ),
                    trailing: DropdownButton<CropStyle>(
                      value: cropStyle,
                      onChanged: (value) {
                        if (value != null) {
                          AppSettings.instance.cropStyle.value = value;
                        }
                      },
                      items: [
                        for (final style in CropStyle.values)
                          DropdownMenuItem(value: style, child: Text(cropStyleLabel(style))),
                      ],
                    ),
                  ),
                ),
                ValueListenableBuilder<ClassificationThresholds>(
                  valueListenable: AppSettings.instance.classificationThresholds,
                  builder: (context, thresholds, _) => _ThresholdSettings(thresholds),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionCard(
            icon: Icons.info_outline_rounded,
            title: 'About',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ReefSight -- coral reef health survey'),
                SizedBox(height: 8),
                Text(
                  'Segmentation model: ${ModelAssets.stageBSegmentation}\n'
                  'Bleaching classifier: ${ModelAssets.nmfsOsiBleachingClassifier}',
                  style: TextStyle(fontSize: 12),
                ),
                SizedBox(height: 8),
                Text(
                  'Both models are interim and not yet fine-tuned on Cordova '
                  'reef data.',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            icon: Icons.storage_outlined,
            title: 'Data',
            child: FutureBuilder<int>(
              future: _sessionCount,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
                    'Couldn\'t read survey data: ${snapshot.error}',
                    style: const TextStyle(fontSize: 13, color: Colors.redAccent),
                  );
                }
                final count = snapshot.data;
                return Text(
                  count == null
                      ? 'Loading...'
                      : 'Stored on-device (app documents directory). '
                          '$count survey${count == 1 ? '' : 's'} recorded. '
                          'Long-press a survey in Surveys to delete it.',
                  style: const TextStyle(fontSize: 13),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The four classification thresholds as dropdowns, each a fixed set of
/// choices around sub-plan 10's starting value (marked "(default)"), plus a
/// reset. Writes [AppSettings.classificationThresholds]; Live reads it once
/// per transect, like the crop style.
class _ThresholdSettings extends StatelessWidget {
  const _ThresholdSettings(this.thresholds);

  final ClassificationThresholds thresholds;

  void _set(ClassificationThresholds value) =>
      AppSettings.instance.classificationThresholds.value = value;

  Widget _tile<T extends num>({
    required String id,
    required String title,
    required String subtitle,
    required T value,
    required T defaultValue,
    required List<T> choices,
    required void Function(T) onChanged,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: DropdownButton<T>(
      key: ValueKey('threshold-$id'),
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: [
        for (final choice in choices)
          DropdownMenuItem(
            value: choice,
            child: Text(choice == defaultValue ? '$choice (default)' : '$choice'),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    const d = ClassificationThresholds.defaults;
    return Column(
      children: [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Classification thresholds'),
          subtitle: Text(
            'Comparison only. Applies from the next transect, and is saved '
            'with it and shown on its report. Leave at the defaults for real '
            'surveys.',
          ),
        ),
        _tile<double>(
          id: 'segFloor',
          title: 'Segmentation floor',
          subtitle: 'Detections scored below this are never classified.',
          value: thresholds.segFloor,
          defaultValue: d.segFloor,
          choices: const [0.3, 0.4, 0.5, 0.6],
          onChanged: (v) => _set(thresholds.copyWith(segFloor: v)),
        ),
        _tile<double>(
          id: 'minCoverage',
          title: 'Mask coverage',
          subtitle: 'Inside-mask crops with less coral than this are skipped.',
          value: thresholds.minCoverage,
          defaultValue: d.minCoverage,
          choices: const [0.4, 0.5, 0.6, 0.7],
          onChanged: (v) => _set(thresholds.copyWith(minCoverage: v)),
        ),
        _tile<double>(
          id: 'confFloor',
          title: 'Confidence floor',
          subtitle: 'Classifications below this are recorded as uncertain.',
          value: thresholds.confFloor,
          defaultValue: d.confFloor,
          choices: const [0.55, 0.6, 0.65, 0.7, 0.8],
          onChanged: (v) => _set(thresholds.copyWith(confFloor: v)),
        ),
        _tile<int>(
          id: 'minConfidentSamples',
          title: 'Confident samples',
          subtitle: 'Needed before a colony gets a label.',
          value: thresholds.minConfidentSamples,
          defaultValue: d.minConfidentSamples,
          choices: const [1, 2, 3],
          onChanged: (v) => _set(thresholds.copyWith(minConfidentSamples: v)),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('threshold-reset'),
            onPressed: thresholds.isDefault ? null : () => _set(d),
            child: const Text('Reset to defaults'),
          ),
        ),
      ],
    );
  }
}
