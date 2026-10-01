import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/report_data.dart';
import '../services/report_exporter.dart';
import '../services/tracked_colony_record.dart';
import '../services/transect_video.dart';
import '../widgets/health_chip.dart';
import 'app_shell.dart';
import 'video_player_screen.dart';

/// Sub-plan 5 (ui-and-reporting) tasks 4-5, restyled by sub-plan 6
/// (ui-ux-overhaul) step 4: the post-dive report, two tabs on one dataset
/// per `ReefSight_Specification.md`'s "Post-dive report" line -- Executive
/// (LGU/decision-maker audience) and Technical (academic panel). The
/// Executive tab's content is unchanged by sub-plan 6 (Spec line 125 marks
/// it `[OPEN]`); this pass only applies the shared theme, adds a header, and
/// fixes the back-stack so Summary always returns to [AppShell], never to
/// Transect Setup (sub-plan 6 step 4).
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({
    super.key,
    required this.sessionId,
    this.openDatabase = openAppDatabase,
  });

  final int sessionId;

  /// Injectable so widget tests can substitute an in-memory DB instead of
  /// `path_provider` (no platform channel under `flutter test`).
  final DatabaseOpener openDatabase;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late final Future<TransectReport> _reportFuture = _loadReport();

  /// The session's recording, if one exists on disk -- resolved alongside
  /// the report (see `transect_video.dart` for why the stored path alone
  /// isn't trusted). `null` means no playable video for this session.
  File? _videoFile;

  Future<TransectReport> _loadReport() async {
    final db = await widget.openDatabase();
    try {
      final session = await db.sessionById(widget.sessionId);
      if (session == null) {
        throw StateError('Transect session ${widget.sessionId} not found');
      }
      final colonies = await db.colonyRowsForSession(widget.sessionId);
      try {
        _videoFile = await resolveTransectVideo(session.videoPath);
      } catch (error) {
        // A video lookup failure (e.g. no path_provider under tests) must
        // not take the whole report down with it.
        debugPrint('ReefSight: failed to resolve transect video: $error');
      }
      return TransectReport(session: session, colonies: colonies);
    } finally {
      await db.close();
    }
  }

  /// Sub-plan 6 step 4: "Back from Summary must never land on Transect
  /// Setup." Pops every route above the shell in one call, regardless of how
  /// the diver got here -- the End Transect handoff
  /// (`live_transect_screen.dart`'s `_endTransect`) or opening a past survey
  /// from Home/Surveys. A plain `pop()` would only remove this one route and
  /// land on whatever pushed it (Setup, in the End Transect case), which is
  /// exactly the bug this fixes.
  void _done() =>
      Navigator.of(context).popUntil(ModalRoute.withName(AppShell.routeName));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Transect report'),
        actions: [
          TextButton(
            onPressed: _done,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Done'),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<TransectReport>(
          future: _reportFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load report: ${snapshot.error}'),
              );
            }
            return _ReportBody(report: snapshot.data!, videoFile: _videoFile);
          },
        ),
      ),
    );
  }
}

/// New in sub-plan 6 step 4: "add a header showing site, date, and tape
/// length" -- shared across both tabs, so it replaces the identity block the
/// old Executive tab used to render at the top of its own `ListView`.
class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, this.videoFile});

  final TransectReport report;
  final File? videoFile;

  @override
  Widget build(BuildContext context) {
    final session = report.session;
    final video = videoFile;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          color: AppColors.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.siteName ?? 'Unnamed site',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${session.startedAt.toLocal().toString().substring(0, 16)}'
                ' · ${session.tapeLengthMeters.toStringAsFixed(0)}m transect'
                '${session.observerName == null ? '' : ' · ${session.observerName}'}',
                style: TextStyle(
                  color: AppColors.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              _SessionNotice(report: report),
              // Shared header, so the recording is reachable from either
              // tab -- not only the bottom of the Technical tab's list.
              if (video != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.play_circle_outline_rounded),
                    label: const Text('Watch transect video'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => VideoPlayerScreen(
                          file: video,
                          title: session.siteName ?? 'Transect video',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _ReportTabs(report: report, videoFile: video)),
      ],
    );
  }
}

/// Sub-plan 11 step 4: says what was kept when Live never reached End
/// Transect (crash, iOS kill, long background stay), and how often Live was
/// interrupted. Labels only -- sessions stay immutable (Spec, "Cloud
/// sync"), so an incomplete session is never closed or edited afterwards.
/// The stop time is the last checkpoint (`SessionCheckpointer`), the latest
/// moment the colony rows are known to reflect.
class _SessionNotice extends StatelessWidget {
  const _SessionNotice({required this.report});

  final TransectReport report;

  static String _hhmm(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _times(int count) => switch (count) {
        1 => 'once',
        2 => 'twice',
        _ => '$count times',
      };

  @override
  Widget build(BuildContext context) {
    final session = report.session;
    final lines = <String>[];

    if (session.endedAt == null) {
      final count = report.totalColonies;
      final colonies = count == 1 ? '1 colony was' : '$count colonies were';
      final stoppedAt = session.lastCheckpointAt;
      lines.add(
        stoppedAt == null
            ? 'Incomplete — $colonies saved.'
            : 'Incomplete — the app stopped at ${_hhmm(stoppedAt)}. '
                '$colonies saved up to then.',
      );
    }
    final interruptions = session.interruptionCount ?? 0;
    if (interruptions > 0) {
      lines.add(
        'The app was interrupted ${_times(interruptions)} during this transect.',
      );
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    style: const TextStyle(
                      color: AppColors.onSurface,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportTabs extends StatelessWidget {
  const _ReportTabs({required this.report, this.videoFile});

  final TransectReport report;
  final File? videoFile;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: AppColors.primary,
            child: const TabBar(
              tabs: [Tab(text: 'Executive Summary'), Tab(text: 'Technical Detail')],
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ExecutiveTab(report: report),
                _TechnicalTab(report: report, videoFile: videoFile),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// LGU/decision-maker audience: a healthy/bleached donut and bleaching
/// prevalence framed in plain language -- no track IDs, confidence numbers,
/// or size-frequency detail (that's the Technical tab). Content is
/// unchanged from sub-plan 5 -- Spec line 125 marks this tab `[OPEN]`, and
/// this sub-plan restyles what exists rather than inventing new content.
class _ExecutiveTab extends StatelessWidget {
  const _ExecutiveTab({required this.report});

  final TransectReport report;

  @override
  Widget build(BuildContext context) {
    final prevalence = report.bleachingPrevalenceFraction;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SizedBox(
          height: 190,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 58,
                  startDegreeOffset: -90,
                  sections: _donutSections(report),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${report.totalColonies}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: AppColors.onSurface,
                    ),
                  ),
                  Text(
                    report.totalColonies == 1 ? 'colony' : 'colonies',
                    style: TextStyle(
                      color: AppColors.onSurface.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Sub-plan 10: prevalence below is over the classified colonies
        // only, so show that denominator next to the total.
        Text(
          '${report.totalColonies} '
          '${report.totalColonies == 1 ? 'colony' : 'colonies'} · '
          '${report.classifiedCount} classified · '
          '${report.uncertainCount} uncertain',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.onSurface.withValues(alpha: 0.7),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 16),
        // Out of the classified colonies, matching the prevalence sentence
        // below -- with many Uncertain colonies, dividing by the total would
        // make the bars and the percentage disagree.
        HealthBar(
          label: 'Healthy',
          count: report.healthyCount,
          total: report.classifiedCount,
          color: AppColors.healthy,
        ),
        const SizedBox(height: 8),
        HealthBar(
          label: 'Bleached',
          count: report.bleachedCount,
          total: report.classifiedCount,
          color: AppColors.bleached,
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              prevalence == null
                  ? 'No colonies were successfully classified this session.'
                  : '${(prevalence * 100).toStringAsFixed(0)}% of surveyed '
                      'colonies showed signs of bleaching.',
              style: const TextStyle(color: AppColors.onSurface, fontSize: 14),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Density: ${report.densityPerSquareMeter.toStringAsFixed(2)} '
          'colonies/m²',
          style: const TextStyle(color: AppColors.onSurface, fontSize: 14),
        ),
      ],
    );
  }

  List<PieChartSectionData> _donutSections(TransectReport report) {
    if (report.totalColonies == 0) {
      return [
        PieChartSectionData(value: 1, color: Colors.grey.shade300, title: '', radius: 34),
      ];
    }
    final sections = <PieChartSectionData>[];
    void add(int count, Color color) {
      if (count == 0) return;
      final pct = (count / report.totalColonies * 100).round();
      sections.add(
        PieChartSectionData(
          value: count.toDouble(),
          color: color,
          title: pct >= 8 ? '$pct%' : '',
          titleStyle: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
          radius: 34,
        ),
      );
    }

    add(report.healthyCount, AppColors.healthy);
    add(report.bleachedCount, AppColors.bleached);
    add(report.uncertainCount, AppColors.unknown);
    return sections;
  }
}

/// Academic-panel audience: per-colony detail, size-frequency histogram,
/// and CSV export/share.
class _TechnicalTab extends StatefulWidget {
  const _TechnicalTab({required this.report, this.videoFile});

  final TransectReport report;

  /// Already resolved to an existing file (or `null`) by
  /// `_SummaryScreenState._loadReport`.
  final File? videoFile;

  @override
  State<_TechnicalTab> createState() => _TechnicalTabState();
}

class _TechnicalTabState extends State<_TechnicalTab> {
  bool _isExporting = false;
  String? _exportError;
  String? _csvPath;

  bool _isSharingVideo = false;
  String? _videoShareError;

  Future<void> _shareVideo(String videoPath) async {
    setState(() {
      _isSharingVideo = true;
      _videoShareError = null;
    });
    try {
      await ReportExporter.shareVideo(videoPath);
      if (!mounted) return;
      setState(() => _isSharingVideo = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSharingVideo = false;
        _videoShareError = error.toString();
      });
    }
  }

  Future<void> _exportAndShare() async {
    setState(() {
      _isExporting = true;
      _exportError = null;
    });
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final path = await ReportExporter.exportCsv(
        outputDirectory: documentsDir.path,
        session: widget.report.session,
        colonies: widget.report.colonies,
      );
      if (!mounted) return;
      setState(() {
        _csvPath = path;
        _isExporting = false;
      });
      await ReportExporter.shareCsv(path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isExporting = false;
        _exportError = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Density: ${report.densityPerSquareMeter.toStringAsFixed(2)} '
          'colonies/m²   ·   '
          'Bleaching prevalence: '
          '${report.bleachingPrevalenceFraction == null ? '--' : '${(report.bleachingPrevalenceFraction! * 100).toStringAsFixed(1)}%'}',
          style: const TextStyle(color: AppColors.onSurface, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Text(
          'Size-Frequency Distribution',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: AppColors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        _SizeFrequencyChart(report: report),
        const SizedBox(height: 24),
        const Text(
          'Tracked Colonies',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: AppColors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        ...report.colonies.map((colony) => _ColonyDetailRow(colony: colony)),
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _isExporting ? null : _exportAndShare,
            icon: _isExporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
            label: Text(_isExporting ? 'Exporting...' : 'Export & Share CSV'),
          ),
        ),
        if (_csvPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Saved: ${_csvPath!.split(Platform.pathSeparator).last}',
              style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6), fontSize: 12),
            ),
          ),
        if (_exportError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Export failed: $_exportError',
              style: const TextStyle(color: AppColors.bleached, fontSize: 12),
            ),
          ),
        if (widget.videoFile != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _isSharingVideo ? null : () => _shareVideo(widget.videoFile!.path),
                icon: _isSharingVideo
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.videocam_outlined),
                label: Text(_isSharingVideo ? 'Sharing...' : 'Share Transect Video'),
              ),
            ),
          ),
        if (_videoShareError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Share failed: $_videoShareError',
              style: const TextStyle(color: AppColors.bleached, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _SizeFrequencyChart extends StatelessWidget {
  const _SizeFrequencyChart({required this.report});

  final TransectReport report;

  @override
  Widget build(BuildContext context) {
    final bins = report.sizeFrequencyHistogram(binCount: 6);
    if (bins.isEmpty || bins.every((b) => b.count == 0)) {
      return Container(
        height: 100,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Text(
          'No colony sizes recorded this session.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
      );
    }

    final maxCount = bins.map((b) => b.count).reduce((a, b) => a > b ? a : b);

    return Container(
      height: 180,
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: BarChart(
        BarChartData(
          maxY: (maxCount + 1).toDouble(),
          barGroups: [
            for (var i = 0; i < bins.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: bins[i].count.toDouble(),
                    color: AppColors.primary,
                    width: 14,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ),
          ],
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 24),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 || i >= bins.length) return const SizedBox.shrink();
                  return Text(
                    bins[i].rangeStart.toStringAsFixed(0),
                    style: const TextStyle(fontSize: 8),
                  );
                },
              ),
            ),
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }
}

class _ColonyDetailRow extends StatelessWidget {
  const _ColonyDetailRow({required this.colony});

  final TrackedColonyRecord colony;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forHealth(colony.healthLabel);
    final maskPath = colony.maskPath;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Row(
        children: [
          if (maskPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                File(maskPath),
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox(width: 32, height: 32),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Track #${colony.trackId}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                HealthChip(healthLabel: colony.healthLabel),
              ],
            ),
          ),
          Text(
            colony.sizePx == null ? '--' : '${colony.sizePx!.toStringAsFixed(0)}px²',
            style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
