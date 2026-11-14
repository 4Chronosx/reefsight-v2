import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/geo_fix.dart';
import '../services/laptop_analysis.dart';
import '../services/transect_cover.dart';
import '../services/report_data.dart';
import '../services/session_files.dart';
import '../services/session_summary.dart';
import '../services/station.dart';
import '../services/station_checks.dart';
import '../services/station_summary.dart' show kNoSummaryYet;
import '../services/transect_session.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';
import 'app_shell.dart' show routeObserver;
import 'station_edit_screen.dart';
import 'station_summary_screen.dart';
import 'station_transect_setup_screen.dart';
import 'summary_screen.dart';

typedef TransectSetupBuilder = Widget Function(Station station);

/// Issue #2: one station -- its details and TB 2019-04 flags, its transects
/// (T1-T5) with status and flags, "Add transect", and the entry point for
/// the station summary (#8, disabled until then).
///
/// Reloads after every route it pushes returns, so a transect set up,
/// captured or edited shows without a manual refresh. Long-press a
/// transect to delete it, like a survey card.
class StationDetailScreen extends StatefulWidget {
  const StationDetailScreen({
    super.key,
    required this.stationId,
    this.openDatabase = openAppDatabase,
    this.deleteFiles = deleteSessionFilesInDocuments,
    this.buildTransectSetup,
    this.buildCapture,
    this.exportForAnalysis,
    this.pickResultsFile,
  });

  /// Named so Live's end handoff can return a station transect's Summary
  /// onto this screen (`live_transect_screen.dart`). Push it with
  /// [route], which sets the name.
  static const routeName = '/station';

  static MaterialPageRoute<void> route(int stationId, DatabaseOpener openDatabase) =>
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        builder: (_) => StationDetailScreen(stationId: stationId, openDatabase: openDatabase),
      );

  final int stationId;
  final DatabaseOpener openDatabase;
  final SessionFilesDeleter deleteFiles;

  /// Builds the transect setup; `null` uses the real one with
  /// [openDatabase]. Injectable so tests can hand it fake device checks.
  final TransectSetupBuilder? buildTransectSetup;

  /// What tapping a photo or preliminary transect opens: its capture flow
  /// (#4 photo capture and review), [buildCaptureScreen] by default.
  /// Injected in tests, which have no camera.
  final Widget Function(CaptureStart start)? buildCapture;

  /// Issue #7: packs the station for the laptop notebook and opens the
  /// share sheet; `null` uses [LaptopAnalysis] with the app's directories.
  /// Injected in tests, which have no share sheet.
  final Future<void> Function(int stationId)? exportForAnalysis;

  /// Issue #7: the text of the results file the diver picks, or `null` when
  /// they cancel; `null` uses the Files picker. Injected in tests.
  final Future<String?> Function()? pickResultsFile;

  @override
  State<StationDetailScreen> createState() => _StationDetailScreenState();
}

class _StationData {
  const _StationData(this.station, this.transects, [this.colonyResults = const {}, this.cover = const {}]);

  final Station? station;
  final List<TransectSession> transects;

  /// Issue #3: each colony-count transect's own counts, by session id.
  /// Empty for photo and preliminary stations.
  final Map<int, SessionSummary> colonyResults;

  /// Issue #7: each transect's cached cover rows, by session id. Empty for
  /// colony-count stations.
  final Map<int, List<TransectCoverRow>> cover;
}

/// `StateError`'s and `ArgumentError`'s own message, without the
/// "Bad state:" / "Invalid argument(s):" prefix.
String _reason(Object error) => switch (error) {
      StateError(:final message) => message,
      ArgumentError(:final message) => '$message',
      FormatException(:final message) => message,
      _ => '$error',
    };

Future<void> _exportWithLaptopAnalysis(int stationId, DatabaseOpener openDatabase) async {
  final db = await openDatabase();
  final AnalysisExport export;
  try {
    export = await LaptopAnalysis.exportStation(
      db,
      stationId,
      documentsPath: (await getApplicationDocumentsDirectory()).path,
      outputDirectory: await getTemporaryDirectory(),
    );
  } finally {
    await db.close();
  }
  await LaptopAnalysis.share(export.zipPath);
}

/// `FileType.custom` goes through the Files app on iOS (`photo_source.dart`).
Future<String?> _pickResultsFromFiles() async {
  final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
  final path = result?.files.singleOrNull?.path;
  if (path == null) return null;
  final file = File(path);
  if (await file.length() > LaptopAnalysis.maxResultsBytes) {
    throw const FormatException('This file is far too large to be a ReefSight results file');
  }
  return file.readAsString();
}

class _StationDetailScreenState extends State<StationDetailScreen> with RouteAware {
  late Future<_StationData> _data = _load();

  // A colony-count Summary is pushed by Live straight onto this route
  // (removing Setup and Live), so `_push`'s await never sees it pop; the
  // route observer does.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() => _reload();

  Future<_StationData> _load() async {
    final db = await widget.openDatabase();
    try {
      final station = await db.stationById(widget.stationId);
      final transects =
          station == null ? const <TransectSession>[] : await db.transectsForStation(widget.stationId);
      final colonyCount = station?.surveyType == SurveyType.colonyCount;
      final results =
          colonyCount ? await db.colonyResultsForStation(widget.stationId) : const <int, SessionSummary>{};
      final cover = <int, List<TransectCoverRow>>{
        if (!colonyCount)
          for (final t in transects) t.id!: await db.coverForSession(t.id!),
      };
      return _StationData(station, transects, results, cover);
    } finally {
      await db.close();
    }
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _data = _load();
    });
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  void _addTransect(Station station) => _push(
        widget.buildTransectSetup?.call(station) ??
            StationTransectSetupScreen(station: station, openDatabase: widget.openDatabase),
      );

  void _edit(Station station, int transectCount) => _push(
        StationEditScreen(
          existing: station,
          transectCount: transectCount,
          openDatabase: widget.openDatabase,
        ),
      );

  Widget _defaultCapture(CaptureStart start) =>
      buildCaptureScreen(start, openDatabase: widget.openDatabase);

  void _openTransect(Station station, TransectSession t) => _push(
        station.surveyType == SurveyType.colonyCount
            ? SummaryScreen(sessionId: t.id!, openDatabase: widget.openDatabase)
            : (widget.buildCapture ?? _defaultCapture)(
                CaptureStart(station: station, sessionId: t.id!, transectNumber: t.transectNumber ?? 0),
              ),
      );

  bool _analysisBusy = false;

  Future<void> _exportForAnalysis(Station station) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _analysisBusy = true);
    try {
      final export = widget.exportForAnalysis ?? (id) => _exportWithLaptopAnalysis(id, widget.openDatabase);
      await export(station.id!);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: ${_reason(error)}')));
    } finally {
      if (mounted) setState(() => _analysisBusy = false);
      _reload();
    }
  }

  Future<void> _importResults() async {
    // Busy before the picker opens, so a second tap can't open another.
    setState(() => _analysisBusy = true);
    String title;
    String message;
    try {
      final text = await (widget.pickResultsFile ?? _pickResultsFromFiles)();
      if (text == null) return;
      final db = await widget.openDatabase();
      try {
        message = describeImport(await LaptopAnalysis.importResults(db, text, stationId: widget.stationId));
        title = 'Results imported';
      } finally {
        await db.close();
      }
    } on FormatException catch (error) {
      (title, message) = ('Results not imported', _reason(error));
    } on ArgumentError catch (error) {
      (title, message) = ('Results not imported', "They don't match this phone's transects: ${_reason(error)}");
    } catch (error) {
      (title, message) = ('Results not imported', 'Something went wrong: ${_reason(error)}');
    } finally {
      if (mounted) setState(() => _analysisBusy = false);
    }
    if (!mounted) return;
    _reload();
    await _showAnalysisDialog(title, message);
  }

  Future<void> _showAnalysisDialog(String title, String message) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );

  Future<void> _deleteTransect(TransectSession t) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete T${t.transectNumber}?'),
        content: const Text(
          "Its frames, points, colonies and files are removed from this phone. This can't be "
          'undone, and its number is not given to a new transect automatically.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final db = await widget.openDatabase();
      final TransectSession? deleted;
      try {
        deleted = await db.deleteSession(t.id!);
      } finally {
        await db.close();
      }
      if (deleted != null) {
        try {
          await widget.deleteFiles(deleted);
        } catch (error) {
          debugPrint('ReefSight: deleting transect ${t.id} files failed: $error');
        }
      }
      messenger.showSnackBar(SnackBar(content: Text('T${t.transectNumber} deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $error')));
    } finally {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_StationData>(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final station = data?.station;
        if (snapshot.connectionState != ConnectionState.done || station == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Station')),
            body: Center(
              child: snapshot.connectionState != ConnectionState.done
                  ? const CircularProgressIndicator()
                  : Text(snapshot.hasError ? 'Could not load: ${snapshot.error}' : 'Station not found'),
            ),
          );
        }
        final transects = data!.transects;
        final full = transects.length >= kMaxTransects;
        final flags = stationFlags(station, transects.length);
        final hasCover = data.cover.values.any((rows) => rows.isNotEmpty);

        return Scaffold(
          appBar: AppBar(
            title: Text(station.code),
            actions: [
              IconButton(
                tooltip: 'Edit station',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(station, transects.length),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StationCard(station: station, flags: flags),
                const SizedBox(height: 16),
                SectionCard(
                  icon: Icons.linear_scale_rounded,
                  title: 'Transects (${transects.length} of $kMaxTransects)',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (transects.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'No transects yet. TB 2019-04 asks for 3-5 per station.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      for (final t in transects)
                        _TransectRow(
                          transect: t,
                          status: transectStatus(t, station.surveyType),
                          flags: transectFlags(t),
                          colonyResults: data.colonyResults[t.id],
                          coverLine: transectCoverLine(data.cover[t.id] ?? const [], t.analyzedOn),
                          onTap: () => _openTransect(station, t),
                          onLongPress: () => _deleteTransect(t),
                        ),
                      const SizedBox(height: 8),
                      GloveButton(
                        label: 'Add transect',
                        onPressed: full ? null : () => _addTransect(station),
                      ),
                    ],
                  ),
                ),
                // Issue #7: the cover segmenter runs on a laptop until the
                // phone bridge (#12). Preliminary frames get points with #13.
                if (station.surveyType == SurveyType.photoTransect) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    icon: Icons.laptop_outlined,
                    title: 'Cover analysis (laptop)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Export the photos and their 10 points per frame, run the Coralscapes '
                            'notebook on a laptop, then import its results.json here.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _analysisBusy ? null : () => _exportForAnalysis(station),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Export for laptop analysis'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _analysisBusy ? null : _importResults,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Import analysis results'),
                        ),
                        if (_analysisBusy)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: LinearProgressIndicator(),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Issue #3: colony count has no station cover summary -- its
                // results stay per transect (alignment doc §10).
                if (!reportsBulletinCover(station.surveyType))
                  Text(
                    kColonyCountNoStationSummary,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13, height: 1.4),
                  )
                else ...[
                  // Issue #8: open once any transect has cover.
                  OutlinedButton.icon(
                    onPressed: hasCover
                        ? () => _push(StationSummaryScreen(stationId: station.id!, openDatabase: widget.openDatabase))
                        : null,
                    icon: const Icon(Icons.summarize_outlined),
                    label: const Text('Station summary'),
                  ),
                  if (!hasCover)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(kNoSummaryYet, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({required this.station, required this.flags});

  final Station station;
  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    final d = station.surveyedOn;
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final zone = station.reefZone;
    final fix = station.deepEdgeFix;
    final min = station.depthMinM;
    final max = station.depthMaxM;
    final depth = min == null && max == null
        ? null
        : '${min?.toString() ?? '?'}-${max?.toString() ?? '?'} m';
    final lines = [
      [
        surveyTypeLabel(station.surveyType),
        if (station.frameMode != null) frameModeLabel(station.frameMode!),
      ].join(' · '),
      [date, ?station.siteName, ?station.observerName].join(' · '),
      if (zone != null || depth != null) [if (zone != null) reefZoneLabel(zone), ?depth].join(' · '),
      'Deep edge: ${fix == null ? 'no fix' : formatFix(fix)}'
          '${station.markerPlaced == true ? ' · marker placed' : ''}',
    ];
    return SectionCard(
      icon: Icons.flag_outlined,
      title: station.name ?? station.code,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: const TextStyle(fontSize: 13)),
            ),
          // Issue #3: said on the station itself, not only in its reports.
          if (!reportsBulletinCover(station.surveyType))
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.science_outlined, size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      kResearchScopeNote,
                      style: TextStyle(fontSize: 12, color: AppColors.primary),
                    ),
                  ),
                ],
              ),
            ),
          for (final flag in flags) ...[
            const SizedBox(height: 4),
            FlagLine(flag),
          ],
        ],
      ),
    );
  }
}

class _TransectRow extends StatelessWidget {
  const _TransectRow({
    required this.transect,
    required this.status,
    required this.flags,
    this.colonyResults,
    this.coverLine,
    required this.onTap,
    required this.onLongPress,
  });

  final TransectSession transect;
  final String status;
  final List<String> flags;

  /// Issue #7: `transectCoverLine`, or `null` while there is no cover.
  final String? coverLine;

  /// Issue #3: a colony-count transect's own counts; `null` otherwise.
  final SessionSummary? colonyResults;

  /// "N colonies · X% bleached (…)", Surveys' card wording -- or nothing
  /// at all while a blinded recount is pending (sub-plan 14).
  String? get _resultsLine {
    final r = colonyResults;
    if (r == null) return null;
    if (transect.resultsCurrentlyHidden) return 'Results hidden — recount pending';
    if (r.colonyCount == 0) return '0 colonies';
    final prevalence = PrevalenceEstimate.of(bleached: r.bleachedCount, classified: r.classifiedCount);
    return '${r.colonyCount} colonies · ${prevalence?.cardLabel ?? 'None classified'}';
  }
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = transect;
    final depths = [t.depthStartM, t.depthEndM].every((d) => d == null)
        ? null
        : '${t.depthStartM?.toString() ?? '?'}-${t.depthEndM?.toString() ?? '?'} m deep';
    final placement = t.randomAlongM == null && t.randomSwimoutM == null
        ? null
        : '${t.randomAlongM?.toString() ?? '?'} m along, ${t.randomSwimoutM?.toString() ?? '?'} m out';
    final detail = ['${t.tapeLengthMeters.toStringAsFixed(0)} m tape', ?depths, ?placement].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'T${t.transectNumber}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const Spacer(),
                  Text(status, style: const TextStyle(color: AppColors.unknown, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 4),
              Text(detail, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              if (_resultsLine case final results?) ...[
                const SizedBox(height: 4),
                Text(results, style: const TextStyle(fontSize: 13)),
              ],
              if (coverLine case final cover?) ...[
                const SizedBox(height: 4),
                Text(cover, style: const TextStyle(fontSize: 13)),
              ],
              for (final flag in flags) ...[
                const SizedBox(height: 4),
                FlagLine(flag),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
