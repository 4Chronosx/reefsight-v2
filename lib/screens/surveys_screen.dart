import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/session_summary.dart';
import '../widgets/glove_button.dart';
import 'summary_screen.dart';
import 'transect_setup_screen.dart';

/// Sub-plan 6 (ui-ux-overhaul), step 4: the Surveys (history) tab -- every
/// completed or incomplete session in SQLite, reachable for the first time
/// since sub-plan 5 shipped (`TransectDatabase` had no `listSessions` before
/// sub-plan 6 step 2). Read-only: no swipe-to-delete or long-press menu
/// (decision 8 -- surveys are irreversible field data).
class SurveysScreen extends StatefulWidget {
  const SurveysScreen({
    super.key,
    required this.dataRevision,
    this.openDatabase = openAppDatabase,
  });

  /// Bumped by [AppShell] to force a reload -- see `app_shell.dart`'s doc
  /// comment. Also reloaded on tab re-selection via the same mechanism,
  /// since `AppShell` bumps this whenever a pushed route pops back to it,
  /// not only after Summary specifically.
  final int dataRevision;

  final DatabaseOpener openDatabase;

  @override
  State<SurveysScreen> createState() => _SurveysScreenState();
}

class _SurveysScreenState extends State<SurveysScreen> {
  late Future<List<SessionSummary>> _sessions = _load();

  Future<List<SessionSummary>> _load() async {
    final db = await widget.openDatabase();
    try {
      return await db.listSessions();
    } finally {
      await db.close();
    }
  }

  @override
  void didUpdateWidget(covariant SurveysScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataRevision != widget.dataRevision) {
      setState(() => _sessions = _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Surveys')),
      body: FutureBuilder<List<SessionSummary>>(
        future: _sessions,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessions = snapshot.data ?? const [];
          if (sessions.isEmpty) {
            return _EmptyState(
              onStart: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TransectSetupScreen()),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            itemBuilder: (context, i) => _SurveyCard(summary: sessions[i]),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.list_alt_rounded, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              'Completed and in-progress surveys will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),
            GloveButton(label: 'Start your first survey', onPressed: onStart),
          ],
        ),
      ),
    );
  }
}

class _SurveyCard extends StatelessWidget {
  const _SurveyCard({required this.summary});

  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final session = summary.session;
    final incomplete = session.endedAt == null;
    final bleachingPct =
        summary.colonyCount == 0 ? null : summary.bleachedCount / summary.colonyCount;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: session.id!)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.siteName ?? 'Unnamed site',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  if (incomplete)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.unknown.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Incomplete',
                        style: TextStyle(
                          color: AppColors.unknown,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${session.startedAt.toLocal().toString().substring(0, 16)}'
                '${session.observerName == null ? '' : ' · ${session.observerName}'}'
                ' · ${session.tapeLengthMeters.toStringAsFixed(0)}m',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('${summary.colonyCount} colonies', style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 12),
                  if (bleachingPct != null)
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: bleachingPct,
                          backgroundColor: AppColors.healthy.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation(AppColors.bleached),
                          minHeight: 8,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
