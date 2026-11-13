import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/geo_fix.dart';
import '../services/session_files.dart';
import '../services/station.dart';
import '../services/station_checks.dart';
import '../services/transect_session.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';
import 'app_shell.dart' show routeObserver;
import 'capture_placeholder_screen.dart';
import 'station_edit_screen.dart';
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

  @override
  State<StationDetailScreen> createState() => _StationDetailScreenState();
}

class _StationData {
  const _StationData(this.station, this.transects);

  final Station? station;
  final List<TransectSession> transects;
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
      return _StationData(station, transects);
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

  void _openTransect(Station station, TransectSession t) => _push(
        station.surveyType == SurveyType.colonyCount
            ? SummaryScreen(sessionId: t.id!)
            : CapturePlaceholderScreen(
                station: station,
                sessionId: t.id!,
                transectNumber: t.transectNumber ?? 0,
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
                const SizedBox(height: 16),
                // The station summary and CPCe export arrive with #8.
                OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.summarize_outlined),
                  label: const Text('Station summary (coming with #8)'),
                ),
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
    required this.onTap,
    required this.onLongPress,
  });

  final TransectSession transect;
  final String status;
  final List<String> flags;
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
