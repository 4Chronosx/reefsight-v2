import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/report_exporter.dart';
import '../services/station_diversity.dart';
import '../services/station_summary.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';
import 'station_edit_screen.dart' show FlagLine;

/// Writes the station's CPCe sheet (with its diversity, #10) and opens the
/// share sheet.
typedef StationSheetExporter = Future<void> Function(StationCoverSummary summary, StationDiversity? diversity);

Future<void> _exportAndShare(StationCoverSummary summary, StationDiversity? diversity) async {
  final path = await ReportExporter.exportStationCpceCsv(
    outputDirectory: (await getTemporaryDirectory()).path,
    summary: summary,
    diversity: diversity,
  );
  await ReportExporter.shareStationSheet(path, preliminary: summary.isPreliminary);
}

/// Issue #8: a photo-transect or preliminary station's summary --
/// station-mean hard coral cover with its SE and TB 2019-04 grade, % bleached
/// coral, the flags, and the cover table in the CPCe layout (T1…Tn, Mean,
/// SD, SE), with the CPCe sheet export. The rules are
/// `services/station_summary.dart`'s; this screen only shows them.
class StationSummaryScreen extends StatefulWidget {
  const StationSummaryScreen({
    super.key,
    required this.stationId,
    this.openDatabase = openAppDatabase,
    this.exportSheet,
  });

  final int stationId;
  final DatabaseOpener openDatabase;

  /// `null` writes to the temporary directory and opens the share sheet.
  /// Injected in tests, which have no share sheet.
  final StationSheetExporter? exportSheet;

  @override
  State<StationSummaryScreen> createState() => _StationSummaryScreenState();
}

typedef _Loaded = ({StationCoverSummary summary, StationDiversity diversity});

class _StationSummaryScreenState extends State<StationSummaryScreen> {
  late final Future<_Loaded> _summary = _load();
  bool _exporting = false;

  Future<_Loaded> _load() async {
    final db = await widget.openDatabase();
    try {
      final station = await db.stationById(widget.stationId);
      if (station == null) throw StateError('Station not found');
      final summary = StationCoverSummary.compute(station, await db.stationCoverInputs(widget.stationId));
      // Issue #10: over every transect, analyzed or not -- tags don't wait
      // for cover.
      final diversity = StationDiversity.compute(
        await db.transectsForStation(widget.stationId),
        await db.genusTagsForStation(widget.stationId),
      );
      return (summary: summary, diversity: diversity);
    } finally {
      await db.close();
    }
  }

  Future<void> _export(StationCoverSummary summary, StationDiversity diversity) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      await (widget.exportSheet ?? _exportAndShare)(summary, diversity);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Loaded>(
      future: _summary,
      builder: (context, snapshot) {
        final summary = snapshot.data?.summary;
        return Scaffold(
          appBar: AppBar(title: Text(summary == null ? 'Station summary' : 'Summary · ${summary.station.code}')),
          body: SafeArea(
            child: summary == null
                ? Center(
                    child: snapshot.hasError
                        ? Text('Could not load: ${snapshot.error}')
                        : const CircularProgressIndicator(),
                  )
                : _body(summary, snapshot.data!.diversity),
          ),
        );
      },
    );
  }

  Widget _body(StationCoverSummary summary, StationDiversity diversity) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (summary.isPreliminary) ...[
          const _PreliminaryBanner(),
          const SizedBox(height: 16),
        ],
        if (summary.n == 0) ...[
          const Text(kNoCoverYet, style: TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
        ] else ...[
          _HardCoralCard(summary: summary),
          const SizedBox(height: 16),
        ],
        for (final flag in summary.flags)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: FlagLine(flag)),
        const SizedBox(height: 12),
        _DiversityCard(diversity: diversity),
        if (summary.n > 0) ...[
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.table_chart_outlined,
            title: 'Cover by category (% of points counted)',
            child: _CoverTable(summary: summary),
          ),
        ],
        // Diversity alone is worth a sheet: tags don't wait for cover (#10).
        if (summary.n > 0 || diversity.hasTags) ...[
          const SizedBox(height: 16),
          GloveButton(
            label: 'Export CPCe sheet',
            icon: Icons.ios_share,
            busy: _exporting,
            onPressed: _exporting ? null : () => _export(summary, diversity),
          ),
        ],
      ],
    );
  }
}

class _PreliminaryBanner extends StatelessWidget {
  const _PreliminaryBanner();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.amber.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.shade700),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.amber.shade900),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(kPreliminaryStamp, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

class _HardCoralCard extends StatelessWidget {
  const _HardCoralCard({required this.summary});

  final StationCoverSummary summary;

  @override
  Widget build(BuildContext context) {
    final hc = summary.hardCoral!;
    final se = hc.se;
    final total = summary.n + summary.notAnalyzed.length;
    final counts = '${summary.n} of $total transects analyzed';
    final bleached = summary.bleached;
    return SectionCard(
      icon: Icons.grass_outlined,
      title: 'Hard coral cover (station mean)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatPercent1(hc.mean)}%',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: AppColors.primary),
          ),
          Text(se == null ? counts : '± ${formatPercent1(se)} SE · $counts', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Text(summary.gradeLine!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          Text(
            'TB 2019-04 scale: A >44% · B >33-44% · C >22-33% · D 0-22%',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          if (bleached != null) ...[
            const SizedBox(height: 8),
            Text(
              'Bleached coral ${formatPercent1(bleached.mean)}%',
              style: const TextStyle(fontSize: 14, color: AppColors.bleached),
            ),
          ],
        ],
      ),
    );
  }
}

/// Issue #10: distinct TAUs per transect and for the station, the station
/// figure graded on TB 2019-04 Table 2 -- or why there is none yet.
class _DiversityCard extends StatelessWidget {
  const _DiversityCard({required this.diversity});

  final StationDiversity diversity;

  @override
  Widget build(BuildContext context) {
    final perTransect = [for (final t in diversity.transects) 'T${t.transect.transectNumber ?? '?'} ${t.count}'];
    return SectionCard(
      icon: Icons.local_florist_outlined,
      title: 'Generic diversity (station)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!diversity.hasTags)
            const Text(kNoDiversityYet, style: TextStyle(fontSize: 13))
          else ...[
            Text(diversity.gradeLine!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            Text('${perTransect.join(' · ')} TAUs', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text(kDiversityScale, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            for (final flag in diversity.flags)
              Padding(padding: const EdgeInsets.only(top: 4), child: FlagLine(flag)),
          ],
        ],
      ),
    );
  }
}

class _CoverTable extends StatelessWidget {
  const _CoverTable({required this.summary});

  final StationCoverSummary summary;

  @override
  Widget build(BuildContext context) {
    // A dash is a value that doesn't exist (SD with one transect).
    String fixed(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    DataRow statRow(CategoryStat s, {bool major = false}) {
      final style = TextStyle(fontWeight: major ? FontWeight.w600 : FontWeight.normal);
      return DataRow(cells: [
        DataCell(Text(s.name, style: style)),
        for (final v in s.percents) DataCell(Text(fixed(v))),
        DataCell(Text(fixed(s.mean), style: style)),
        DataCell(Text(fixed(s.sd))),
        DataCell(Text(fixed(s.se))),
      ]);
    }

    DataRow countRow(String label, List<int> values) => DataRow(cells: [
          DataCell(Text(label, style: TextStyle(color: Colors.grey.shade700))),
          for (final v in values) DataCell(Text('$v')),
          for (var i = 0; i < 3; i++) const DataCell(Text('')),
        ]);

    final t = summary.analyzed;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 40,
        columns: [
          const DataColumn(label: Text('Category')),
          for (final x in t) DataColumn(label: Text(x.label), numeric: true),
          const DataColumn(label: Text('Mean'), numeric: true),
          const DataColumn(label: Text('SD'), numeric: true),
          const DataColumn(label: Text('SE'), numeric: true),
        ],
        rows: [
          countRow('Frames', [for (final x in t) x.cover.framesScored]),
          countRow('Points counted', [for (final x in t) x.cover.countedPoints]),
          countRow('Excluded', [for (final x in t) x.cover.excludedPoints]),
          for (final m in summary.majors) statRow(m, major: true),
          for (final c in summary.codes) statRow(c),
        ],
      ),
    );
  }
}
