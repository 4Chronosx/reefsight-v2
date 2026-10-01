import 'package:flutter/material.dart';

import '../services/app_database.dart';
import '../services/app_settings.dart';
import '../services/model_assets.dart';
import '../widgets/section_card.dart';

/// Sub-plan 6 (ui-ux-overhaul), step 7: Settings/About -- a diagnostics
/// toggle for Live's debug overlay, an About section disclosing which model
/// assets are bundled and that they're interim (mobile `CLAUDE.md`'s "Models
/// are interim, not final" -- honest disclosure to LGU users and the panel),
/// and a Data section with storage location/session count. No delete/clear
/// action (decision 8: surveys are irreversible field data).
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
            child: ValueListenableBuilder<bool>(
              valueListenable: AppSettings.instance.showDiagnostics,
              builder: (context, showDiagnostics, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show diagnostics on Live'),
                subtitle: const Text(
                  'Per-track debug overlay (segmentation time, track IDs) '
                  'for field debugging.',
                ),
                value: showDiagnostics,
                onChanged: (value) =>
                    AppSettings.instance.showDiagnostics.value = value,
              ),
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
                  'Segmentation model: ${ModelAssets.coralvosPrimarySegmentation}\n'
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
                          'Surveys can\'t be deleted from the app.',
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
