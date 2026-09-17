import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/health_aggregator.dart';
import '../services/report_data.dart';
import '../services/report_exporter.dart';
import '../services/tracked_colony_record.dart';
import '../services/transect_database.dart';

/// Sub-plan 5 (ui-and-reporting) tasks 4-5: the post-dive report, two tabs
/// on one dataset per `ReefSight_Specification.md`'s "Post-dive report"
/// line -- Executive (LGU/decision-maker audience) and Technical
/// (academic panel). Adapted from v1's `summary_screen.dart` (donut chart,
/// health bars) but built on sub-plan 4's real schema, not v1's GPS-quadrat
/// model -- no map tab, no quadrat chart, since this project has no
/// per-quadrat GPS data to back them (see `mobile/sub-plans/
/// 05-ui-and-reporting.md` plan's scoping note).
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key, required this.sessionId});

  final int sessionId;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late final Future<TransectReport> _reportFuture = _loadReport();

  Future<TransectReport> _loadReport() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final db = await TransectDatabase.open(documentsDir.path);
    try {
      final session = await db.sessionById(widget.sessionId);
      if (session == null) {
        throw StateError('Transect session ${widget.sessionId} not found');
      }
      final colonies = await db.colonyRowsForSession(widget.sessionId);
      return TransectReport(session: session, colonies: colonies);
    } finally {
      await db.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
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
            return _ReportTabs(report: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _ReportTabs extends StatelessWidget {
  const _ReportTabs({required this.report});

  final TransectReport report;

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
                _TechnicalTab(report: report),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// LGU/decision-maker audience: session identity, total colonies, a
/// healthy/bleached donut, and bleaching prevalence framed in plain
/// language -- no track IDs, confidence numbers, or size-frequency detail
/// (that's the Technical tab).
class _ExecutiveTab extends StatelessWidget {
  const _ExecutiveTab({required this.report});

  final TransectReport report;

  @override
  Widget build(BuildContext context) {
    final session = report.session;
    final prevalence = report.bleachingPrevalenceFraction;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          session.siteName ?? 'Unknown Site',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: AppColors.onSurface,
          ),
        ),
        if (session.observerName != null)
          Text(
            'Observed by ${session.observerName}',
            style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6)),
          ),
        Text(
          '${session.startedAt.toLocal().toString().substring(0, 16)} '
          '· ${session.tapeLengthMeters.toStringAsFixed(0)}m transect',
          style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 24),
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
        const SizedBox(height: 24),
        _HealthBar(
          label: 'Healthy',
          count: report.healthyCount,
          total: report.totalColonies,
          color: AppColors.healthy,
        ),
        const SizedBox(height: 8),
        _HealthBar(
          label: 'Bleached',
          count: report.bleachedCount,
          total: report.totalColonies,
          color: AppColors.bleached,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Text(
            prevalence == null
                ? 'No colonies were successfully classified this session.'
                : '${(prevalence * 100).toStringAsFixed(0)}% of surveyed '
                    'colonies showed signs of bleaching.',
            style: const TextStyle(color: AppColors.onSurface, fontSize: 14),
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
    add(report.unclassifiedCount, AppColors.unknown);
    return sections;
  }
}

/// Academic-panel audience: per-colony detail, size-frequency histogram,
/// and CSV export/share.
class _TechnicalTab extends StatefulWidget {
  const _TechnicalTab({required this.report});

  final TransectReport report;

  @override
  State<_TechnicalTab> createState() => _TechnicalTabState();
}

class _TechnicalTabState extends State<_TechnicalTab> {
  bool _isExporting = false;
  String? _exportError;
  String? _csvPath;

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
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
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
                Text(
                  colony.healthLabel == null
                      ? 'Unclassified'
                      : colony.healthLabel == HealthAggregator.bleachedLabel
                          ? 'Bleached'
                          : 'Healthy',
                  style: TextStyle(color: color, fontSize: 12),
                ),
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

class _HealthBar extends StatelessWidget {
  const _HealthBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? count / total : 0.0;
    return Row(
      children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 10,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 64,
          child: Text(
            '$count (${(pct * 100).toStringAsFixed(0)}%)',
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
