import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/report_data.dart';
import '../services/report_exporter.dart';
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

  bool _exporting = false;

  /// Sub-plan 14 step 6: one CSV row per recounted survey -- the raw table
  /// behind Phase E's mean absolute error.
  Future<void> _exportRecountComparisons() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final sessions = await _load();
      if (!sessions.any((summary) => summary.session.recount != null)) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No recounted surveys to export yet.')),
        );
        return;
      }
      final documentsDir = await getApplicationDocumentsDirectory();
      final path = await ReportExporter.exportRecountComparisonsCsv(
        outputDirectory: documentsDir.path,
        sessions: sessions,
      );
      await ReportExporter.shareCsv([path]);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Surveys'),
        actions: [
          IconButton(
            tooltip: 'Export recount comparisons',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: _exporting ? null : _exportRecountComparisons,
          ),
        ],
      ),
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
    // Sub-plan 17: over classified colonies (sub-plan 10), with its
    // interval -- the same figure Summary shows. Below the threshold there
    // is no bar, only "too few".
    final prevalence = PrevalenceEstimate.of(
      bleached: summary.bleachedCount,
      classified: summary.classifiedCount,
    );

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
              // Sub-plan 14: no app numbers for a "Recount planned" survey
              // until its results are revealed.
              if (session.resultsCurrentlyHidden)
                Text(
                  'Results hidden — recount pending',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                )
              else
                Row(
                  children: [
                    Text('${summary.colonyCount} colonies', style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 12),
                    if (prevalence != null && prevalence.reliable) ...[
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: prevalence.fraction,
                            backgroundColor: AppColors.healthy.withValues(alpha: 0.15),
                            valueColor: const AlwaysStoppedAnimation(AppColors.bleached),
                            minHeight: 8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    // Flexible + ellipsis: at a large system text scale the
                    // label would otherwise overflow the Row on a narrow phone.
                    if (summary.colonyCount > 0)
                      Flexible(
                        child: Text(
                          prevalence?.cardLabel ?? 'None classified',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: prevalence?.reliable ?? false
                                ? AppColors.bleached
                                : Colors.grey.shade600,
                            fontSize: 12,
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
