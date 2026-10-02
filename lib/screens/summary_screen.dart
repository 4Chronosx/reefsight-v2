import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/colony_photos.dart';
import '../services/device_checks.dart';
import '../services/geo_fix.dart';
import '../services/geo_fix_controller.dart';
import '../services/location_provider.dart';
import '../services/recount_comparison.dart';
import '../services/report_data.dart';
import '../services/report_exporter.dart';
import '../services/tracked_colony_record.dart';
import '../services/transect_session.dart';
import '../services/transect_video.dart';
import '../widgets/colony_photo_views.dart';
import '../widgets/geo_fix_panel.dart';
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
    this.locationProvider = const GeolocatorLocationProvider(),
    this.resolveVideo = resolveTransectVideo,
    this.resolvePhotos = _resolvePhotosInDocuments,
  });

  final int sessionId;

  /// Injectable so widget tests can substitute an in-memory DB instead of
  /// `path_provider` (no platform channel under `flutter test`).
  final DatabaseOpener openDatabase;

  /// Sub-plan 12: the exit fix, recorded after surfacing. Injectable so
  /// widget tests can use a fake.
  final LocationProvider locationProvider;

  /// Finds the session's recording on disk. Injectable because the default
  /// needs `path_provider`, so under `flutter test` there is otherwise never
  /// a video (sub-plan 16's colony play buttons).
  final Future<File?> Function(String? storedPath) resolveVideo;

  /// Sub-plan 18: finds the colonies' photos under the current documents
  /// directory. Injectable for the same reason as [resolveVideo].
  final Future<ColonyPhotoFiles> Function(List<TrackedColonyRecord> colonies)
  resolvePhotos;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

Future<ColonyPhotoFiles> _resolvePhotosInDocuments(List<TrackedColonyRecord> colonies) async {
  final documentsDir = await getApplicationDocumentsDirectory();
  return resolveColonyPhotos(colonies, documentsDirectory: documentsDir.path);
}

class _SummaryScreenState extends State<SummaryScreen> {
  /// Reassigned after the exit fix is recorded (sub-plan 12), so the
  /// header re-reads the stored, now read-only fix from the database.
  late Future<TransectReport> _reportFuture = _loadReport();

  void _reload() {
    setState(() {
      _reportFuture = _loadReport();
    });
  }

  /// The session's recording, if one exists on disk -- resolved alongside
  /// the report (see `transect_video.dart` for why the stored path alone
  /// isn't trusted). `null` means no playable video for this session.
  File? _videoFile;

  /// Sub-plan 18: the colony photos that exist on disk, resolved alongside
  /// the report like [_videoFile].
  ColonyPhotoFiles _photos = ColonyPhotoFiles.empty;

  Future<TransectReport> _loadReport() async {
    final db = await widget.openDatabase();
    try {
      final session = await db.sessionById(widget.sessionId);
      if (session == null) {
        throw StateError('Transect session ${widget.sessionId} not found');
      }
      final colonies = await db.colonyRowsForSession(widget.sessionId);
      try {
        _videoFile = await widget.resolveVideo(session.videoPath);
      } catch (error) {
        // A video lookup failure (e.g. no path_provider under tests) must
        // not take the whole report down with it.
        debugPrint('ReefSight: failed to resolve transect video: $error');
      }
      try {
        _photos = await widget.resolvePhotos(colonies);
      } catch (error) {
        debugPrint('ReefSight: failed to resolve colony photos: $error');
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
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load report: ${snapshot.error}'),
              );
            }
            // A reload (after the exit fix or the recount is saved) keeps
            // the previous report on screen until the new one arrives, so
            // the selected tab isn't reset under the diver.
            final report = snapshot.data;
            if (report == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final exitFix = report.session.exitFix == null
                ? _ExitFixSection(
                    // Keyed by session so a reload never reuses a stale
                    // controller.
                    key: ValueKey('exit-fix-${widget.sessionId}'),
                    session: report.session,
                    openDatabase: widget.openDatabase,
                    locationProvider: widget.locationProvider,
                    onRecorded: _reload,
                  )
                : null;
            // Sub-plan 14: "Recount planned" and nothing revealed yet --
            // the header and the recount form only, no app numbers.
            if (report.session.resultsCurrentlyHidden) {
              return _HiddenResultsBody(
                report: report,
                videoFile: _videoFile,
                exitFix: exitFix,
                openDatabase: widget.openDatabase,
                onChanged: _reload,
              );
            }
            return _ReportBody(
              report: report,
              videoFile: _videoFile,
              photos: _photos,
              exitFix: exitFix,
              openDatabase: widget.openDatabase,
              onRecountSaved: _reload,
            );
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
  const _ReportBody({
    required this.report,
    this.videoFile,
    this.photos = ColonyPhotoFiles.empty,
    this.exitFix,
    required this.openDatabase,
    required this.onRecountSaved,
  });

  final TransectReport report;
  final File? videoFile;
  final ColonyPhotoFiles photos;

  /// Sub-plan 12: the "Record exit position" section, only while the
  /// session has no exit fix.
  final Widget? exitFix;

  /// Sub-plan 14: the Technical tab's "Add recount" writes through these.
  final DatabaseOpener openDatabase;
  final VoidCallback onRecountSaved;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ReportHeader(report: report, videoFile: videoFile, exitFix: exitFix),
        Expanded(
          child: _ReportTabs(
            report: report,
            videoFile: videoFile,
            photos: photos,
            openDatabase: openDatabase,
            onRecountSaved: onRecountSaved,
          ),
        ),
      ],
    );
  }
}

/// Sub-plan 6 step 4's header (site, date, tape length), shared by both
/// tabs -- and, since sub-plan 14, by the hidden-results body, where
/// [hideCounts] keeps the incomplete-session notice from giving away the
/// colony count.
class _ReportHeader extends StatelessWidget {
  const _ReportHeader({
    required this.report,
    this.videoFile,
    this.exitFix,
    this.hideCounts = false,
  });

  final TransectReport report;
  final File? videoFile;
  final Widget? exitFix;
  final bool hideCounts;

  @override
  Widget build(BuildContext context) {
    final session = report.session;
    final video = videoFile;
    return Container(
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
          _FixesLine(session: session),
          ?exitFix,
          _SessionNotice(report: report, hideCounts: hideCounts),
          // Shared header, so the recording is reachable from either tab --
          // not only the bottom of the Technical tab's list.
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
            )
          // No video: say why, instead of silently leaving the button out.
          else if (missingVideoNote(session, video) case final note?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.videocam_off_outlined,
                    size: 16,
                    color: AppColors.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      note,
                      style: TextStyle(
                        color: AppColors.onSurface.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
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

/// Sub-plan 14 step 4: Summary for a "Recount planned" transect whose
/// results haven't been revealed. Only the header (with no colony count)
/// and the recount form: no counts, prevalence, chart or tally. Saving the
/// recount stores it as blind and reveals the report; "Reveal without
/// recount" reveals it with no recount, and any later recount is then
/// stored as not blind. The transect video stays reachable -- ml-03 allows
/// the recount to be done from it.
class _HiddenResultsBody extends StatefulWidget {
  const _HiddenResultsBody({
    required this.report,
    this.videoFile,
    this.exitFix,
    required this.openDatabase,
    required this.onChanged,
  });

  final TransectReport report;
  final File? videoFile;
  final Widget? exitFix;
  final DatabaseOpener openDatabase;
  final VoidCallback onChanged;

  @override
  State<_HiddenResultsBody> createState() => _HiddenResultsBodyState();
}

class _HiddenResultsBodyState extends State<_HiddenResultsBody> {
  bool _revealing = false;
  String? _error;

  Future<void> _reveal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reveal without recount?'),
        content: const Text(
          "The app's results will be shown on this phone. A recount entered "
          'after this is recorded as not blind.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reveal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _revealing = true;
      _error = null;
    });
    try {
      final db = await widget.openDatabase();
      try {
        await db.revealResults(widget.report.session.id!, DateTime.now().toUtc());
      } finally {
        await db.close();
      }
      if (!mounted) return;
      widget.onChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _revealing = false;
        _error = 'Could not reveal the results: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ReportHeader(
          report: widget.report,
          videoFile: widget.videoFile,
          exitFix: widget.exitFix,
          hideCounts: true,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                "The app's results are hidden until the recount is entered.",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Count the colonies along the tape, and how many are bleached, '
                "without looking at the app's numbers.",
                style: TextStyle(
                  color: AppColors.onSurface.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              _RecountForm(
                session: widget.report.session,
                openDatabase: widget.openDatabase,
                onSaved: widget.onChanged,
                blind: true,
              ),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Reveal without recount'),
                  onPressed: _revealing ? null : _reveal,
                ),
              ),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: AppColors.bleached, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Sub-plan 14: the recount form -- total, bleached (at most total), and who
/// counted. Write-once, so Save asks for confirmation first.
/// `TransectDatabase.recordRecount` decides in SQL whether it's blind;
/// [blind] only words the dialog.
class _RecountForm extends StatefulWidget {
  const _RecountForm({
    required this.session,
    required this.openDatabase,
    required this.onSaved,
    required this.blind,
  });

  final TransectSession session;
  final DatabaseOpener openDatabase;
  final VoidCallback onSaved;
  final bool blind;

  @override
  State<_RecountForm> createState() => _RecountFormState();
}

class _RecountFormState extends State<_RecountForm> {
  final _total = TextEditingController();
  final _bleached = TextEditingController();
  final _countedBy = TextEditingController();
  bool _saving = false;
  String? _error;

  static int? _count(TextEditingController controller) {
    final value = int.tryParse(controller.text.trim());
    return value == null || value < 0 ? null : value;
  }

  static String? _countError(TextEditingController controller) =>
      controller.text.trim().isEmpty || _count(controller) != null
          ? null
          : 'Enter a whole number, 0 or more';

  String? get _bleachedError {
    final own = _countError(_bleached);
    if (own != null) return own;
    final total = _count(_total);
    final bleached = _count(_bleached);
    if (total != null && bleached != null && bleached > total) {
      return "Bleached can't be more than the total.";
    }
    return null;
  }

  bool get _isValid {
    final total = _count(_total);
    final bleached = _count(_bleached);
    return total != null &&
        bleached != null &&
        bleached <= total &&
        _countedBy.text.trim().isNotEmpty;
  }

  Future<void> _save() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save the recount?'),
        content: Text(
          "It can't be changed afterwards. "
          '${widget.blind ? "It's recorded as blind, and the app's results are then shown." : "The results were already shown on this phone, so it's recorded as not blind."}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final db = await widget.openDatabase();
      try {
        // `false` means another write got there first; the reload shows
        // whichever recount is stored either way.
        await db.recordRecount(
          widget.session.id!,
          total: _count(_total)!,
          bleached: _count(_bleached)!,
          countedBy: _countedBy.text,
          at: DateTime.now().toUtc(),
        );
      } finally {
        await db.close();
      }
      if (!mounted) return;
      widget.onSaved();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the recount: $error';
      });
    }
  }

  @override
  void dispose() {
    _total.dispose();
    _bleached.dispose();
    _countedBy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('recount-total'),
          controller: _total,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Colonies counted along the tape',
            errorText: _countError(_total),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('recount-bleached'),
          controller: _bleached,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Of those, bleached',
            errorText: _bleachedError,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('recount-by'),
          controller: _countedBy,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Counted by'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _isValid && !_saving ? _save : null,
            child: const Text('Save recount'),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: AppColors.bleached, fontSize: 12)),
          ),
      ],
    );
  }
}

/// How long after a dive the phone's own GPS still counts as the exit
/// position. Past this, Summary offers manual entry only: opening an old
/// survey from Surveys must not stamp wherever the phone is today as the
/// dive's exit.
const kExitGpsWindow = Duration(hours: 12);

/// Sub-plan 12 step 5: both surface fixes in the shared header, plus the
/// entry-exit distance next to the tape length as a QA check for a human
/// -- never used in any metric (density divides by the tape).
class _FixesLine extends StatelessWidget {
  const _FixesLine({required this.session});

  final TransectSession session;

  @override
  Widget build(BuildContext context) {
    final entry = session.entryFix;
    final exit = session.exitFix;
    final style = TextStyle(
      color: AppColors.onSurface.withValues(alpha: 0.6),
      fontSize: 12,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Entry: ${entry == null ? 'not recorded' : formatFix(entry)}', style: style),
          if (exit != null) Text('Exit: ${formatFix(exit)}', style: style),
          if (entry != null && exit != null)
            Text(
              'entry–exit ${distanceMeters(entry, exit).toStringAsFixed(0)} m apart'
              ' · tape ${session.tapeLengthMeters.toStringAsFixed(0)} m',
              key: const ValueKey('entry-exit-distance'),
              style: style,
            ),
        ],
      ),
    );
  }
}

/// Sub-plan 12 step 4: "Record exit position" for a session with no exit
/// fix -- taken after surfacing, never at End Transect (tapped underwater,
/// no signal). Acquiring only proposes a fix; nothing is stored until the
/// diver taps Save, and `TransectDatabase.recordExitFix` stores it once
/// (decision 3). Then [onRecorded] reloads the report and this section is
/// replaced by the read-only fix in [_FixesLine].
class _ExitFixSection extends StatefulWidget {
  const _ExitFixSection({
    super.key,
    required this.session,
    required this.openDatabase,
    required this.locationProvider,
    required this.onRecorded,
  });

  final TransectSession session;
  final DatabaseOpener openDatabase;
  final LocationProvider locationProvider;
  final VoidCallback onRecorded;

  @override
  State<_ExitFixSection> createState() => _ExitFixSectionState();
}

class _ExitFixSectionState extends State<_ExitFixSection> {
  late final GeoFixController _controller = GeoFixController(widget.locationProvider);
  bool _saving = false;
  String? _error;

  /// GPS only within [kExitGpsWindow] of the session's last known moment
  /// -- its end, else its last checkpoint, else its start.
  bool get _allowGps {
    final session = widget.session;
    final last = session.endedAt ?? session.lastCheckpointAt ?? session.startedAt;
    return DateTime.now().toUtc().difference(last) <= kExitGpsWindow;
  }

  Future<void> _save(GeoFix fix) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final db = await widget.openDatabase();
      try {
        // `false` means another write got there first; the reload shows
        // whichever fix is stored either way.
        await db.recordExitFix(widget.session.id!, fix);
      } finally {
        await db.close();
      }
      if (!mounted) return;
      widget.onRecorded();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the exit position: $error';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Exit position',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          GeoFixPanel(
            controller: _controller,
            idleLabel: 'Record exit position',
            allowGps: _allowGps,
            gpsUnavailableNote:
                "This dive ended over ${kExitGpsWindow.inHours} h ago, so the phone's "
                'position now is not the exit position. Enter it from a log instead.',
            confirmLabel: 'Save exit position',
            onConfirm: _save,
            saving: _saving,
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: AppColors.bleached, fontSize: 12)),
        ],
      ),
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
  const _SessionNotice({required this.report, this.hideCounts = false});

  final TransectReport report;

  /// Sub-plan 14: results are hidden, so say the session is incomplete
  /// without saying how many colonies were saved.
  final bool hideCounts;

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

    if (session.endedAt == null && hideCounts) {
      final stoppedAt = session.lastCheckpointAt;
      lines.add(
        stoppedAt == null
            ? 'Incomplete.'
            : 'Incomplete — the app stopped at ${_hhmm(stoppedAt)}.',
      );
    } else if (session.endedAt == null) {
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
  const _ReportTabs({
    required this.report,
    this.videoFile,
    required this.photos,
    required this.openDatabase,
    required this.onRecountSaved,
  });

  final TransectReport report;
  final File? videoFile;
  final ColonyPhotoFiles photos;
  final DatabaseOpener openDatabase;
  final VoidCallback onRecountSaved;

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
                _ExecutiveTab(report: report, photos: photos),
                _TechnicalTab(
                  report: report,
                  videoFile: videoFile,
                  photos: photos,
                  openDatabase: openDatabase,
                  onRecountSaved: onRecountSaved,
                ),
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
  const _ExecutiveTab({required this.report, required this.photos});

  final TransectReport report;
  final ColonyPhotoFiles photos;

  @override
  Widget build(BuildContext context) {
    final prevalence = report.prevalence;

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
            // Sub-plan 17: the interval, or "too few" below
            // `minClassifiedForPrevalence` -- no caveats beyond that here.
            child: Text(
              prevalence?.executiveSentence ??
                  'No colonies were successfully classified this session.',
              style: const TextStyle(color: AppColors.onSurface, fontSize: 14),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Density: ${report.executiveDensityLine}',
          style: const TextStyle(color: AppColors.onSurface, fontSize: 14),
        ),
        const SizedBox(height: 24),
        BleachedColonyStrip(
          colonies: report.colonies,
          photos: photos,
          prevalenceReliable: report.prevalenceReliable,
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
  const _TechnicalTab({
    required this.report,
    this.videoFile,
    required this.photos,
    required this.openDatabase,
    required this.onRecountSaved,
  });

  final TransectReport report;
  final DatabaseOpener openDatabase;
  final VoidCallback onRecountSaved;

  /// Already resolved to an existing file (or `null`) by
  /// `_SummaryScreenState._loadReport`.
  final File? videoFile;

  /// Sub-plan 18: row thumbnails and "Share report with photos".
  final ColonyPhotoFiles photos;

  @override
  State<_TechnicalTab> createState() => _TechnicalTabState();
}

class _TechnicalTabState extends State<_TechnicalTab> {
  /// Sub-plan 13 step 4: says when the phone got hot enough for iOS to
  /// throttle it, so a frame-rate drop in this transect can be explained.
  static String? _thermalNote(ThermalLevel? peak) {
    if (peak == null || peak.index < ThermalLevel.serious.index) return null;
    return 'Device got hot (${peak.name}) during this transect.';
  }

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

  /// Sub-plan 18 step 6: [withPhotos] adds every colony photo on disk to the
  /// shared files, as a plain list (no zip dependency).
  Future<void> _exportAndShare({bool withPhotos = false}) async {
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
      // Sub-plan 12 step 5: the session CSV (both GPS fixes) goes with it --
      // and, sub-plan 14, the recount comparison.
      final sessionPath = await ReportExporter.exportSessionCsv(
        outputDirectory: documentsDir.path,
        session: widget.report.session,
        colonies: widget.report.colonies,
      );
      if (!mounted) return;
      setState(() {
        _csvPath = path;
        _isExporting = false;
      });
      if (withPhotos) {
        await ReportExporter.shareReportWithPhotos(
          [path, sessionPath],
          widget.photos.contextPaths,
        );
      } else {
        await ReportExporter.shareCsv([path, sessionPath]);
      }
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
        // Sub-plan 17: the exact intervals with method and n, always --
        // the small-sample rule only applies to the Executive tab.
        Text(
          report.technicalDensityLine,
          style: const TextStyle(color: AppColors.onSurface, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          report.prevalence?.technicalLine ?? 'Bleaching prevalence: --',
          style: const TextStyle(color: AppColors.onSurface, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          'Intervals are 95% and cover sampling uncertainty only -- not '
          'detector misses, double counts or classifier errors (see the '
          'recount comparison).',
          style: TextStyle(
            color: AppColors.onSurface.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
        if (_thermalNote(report.session.thermalPeak) case final note?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              note,
              style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
            ),
          ),
        const SizedBox(height: 16),
        _RecountSection(
          report: report,
          openDatabase: widget.openDatabase,
          onSaved: widget.onRecountSaved,
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
        ...report.colonies.map(
          (colony) => _ColonyDetailRow(
            colony: colony,
            session: report.session,
            videoFile: widget.videoFile,
            photo: widget.photos.context[colony.trackId],
            crop: widget.photos.crop[colony.trackId],
          ),
        ),
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
        if (widget.photos.contextPaths.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _isExporting ? null : () => _exportAndShare(withPhotos: true),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Share report with photos'),
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

/// Sub-plan 14 step 5, on the Technical tab with results shown: the
/// app-vs-recount comparison once a recount exists, otherwise "Add recount".
/// A recount added here is never blind -- the results are already on screen
/// -- and `TransectDatabase.recordRecount` stores it that way.
class _RecountSection extends StatefulWidget {
  const _RecountSection({
    required this.report,
    required this.openDatabase,
    required this.onSaved,
  });

  final TransectReport report;
  final DatabaseOpener openDatabase;
  final VoidCallback onSaved;

  @override
  State<_RecountSection> createState() => _RecountSectionState();
}

class _RecountSectionState extends State<_RecountSection> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final comparison = widget.report.recountComparison;
    if (comparison != null) return _RecountComparisonCard(comparison: comparison);
    if (!_adding) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Add recount'),
          onPressed: () => setState(() => _adding = true),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Manual recount',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.onSurface),
        ),
        const SizedBox(height: 4),
        Text(
          "The app's results were already shown on this phone, so this recount "
          'is recorded as not blind.',
          style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.7), fontSize: 12),
        ),
        const SizedBox(height: 8),
        _RecountForm(
          session: widget.report.session,
          openDatabase: widget.openDatabase,
          onSaved: widget.onSaved,
          blind: false,
        ),
      ],
    );
  }
}

/// App count vs recount (absolute and percentage error) and app vs recount
/// bleaching prevalence (percentage points), with both denominators named:
/// the app's prevalence is over classified colonies (sub-plan 10), the
/// recount's over all counted colonies.
class _RecountComparisonCard extends StatelessWidget {
  const _RecountComparisonCard({required this.comparison});

  final RecountComparison comparison;

  static String _signedInt(int value) => value > 0 ? '+$value' : '$value';

  static String _signed(double value) =>
      '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)}';

  static String _percent(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final c = comparison;
    final recount = c.recount;
    final errorPct = c.countErrorPercent;
    final diff = c.prevalenceDiffPp;
    final at = recount.at.toLocal().toString().substring(0, 16);
    const style = TextStyle(color: AppColors.onSurface, fontSize: 13);
    return Container(
      key: const ValueKey('recount-comparison'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Manual recount (${recount.blinded ? 'blind' : 'not blind'}) · '
            '${recount.countedBy} · $at',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Colonies: app ${c.appTotal} · recount ${recount.total} · '
            'error ${_signedInt(c.countError)}'
            '${errorPct == null ? '' : ' (${_signed(errorPct)}%)'}',
            style: style,
          ),
          const SizedBox(height: 4),
          Text(
            'Bleaching prevalence: app ${_percent(c.appPrevalencePercent)} · '
            'recount ${_percent(c.recountPrevalencePercent)} · '
            'difference ${diff == null ? '--' : '${_signed(diff)} pp'}',
            style: style,
          ),
          const SizedBox(height: 6),
          Text(
            'App prevalence is over the ${c.appClassified} classified colonies '
            "(Uncertain left out); the recount's is over all ${recount.total} "
            'counted colonies.',
            style: TextStyle(color: AppColors.onSurface.withValues(alpha: 0.6), fontSize: 12),
          ),
        ],
      ),
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

/// Sub-plan 16: with a recording on disk, the row's play button opens it
/// just before this colony first appears, so anyone can check the detection
/// and its health label against the footage.
class _ColonyDetailRow extends StatelessWidget {
  const _ColonyDetailRow({
    required this.colony,
    required this.session,
    this.videoFile,
    this.photo,
    this.crop,
  });

  final TrackedColonyRecord colony;
  final TransectSession session;
  final File? videoFile;

  /// Sub-plan 18: the colony's context photo and classifier crop, when on
  /// disk. With a photo the row shows it instead of the mask.
  final File? photo;
  final File? crop;

  void _openVideo(BuildContext context, File video) {
    final offset = videoOffsetFor(colony, session);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          file: video,
          title: 'Colony #${colony.trackId} · '
              '${formatVideoTime(offset.firstSeen)}–${formatVideoTime(offset.lastSeen)}',
          startAt: offset.start,
          note: offset.approximate
              ? 'Position approximate (recorded before video timing was stored)'
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = videoFile;
    final color = AppColors.forHealth(colony.healthLabel);
    final maskPath = colony.maskPath;
    final photo = this.photo;

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
          if (photo != null)
            ColonyThumbnail(colony: colony, photo: photo, crop: crop)
          else if (maskPath != null)
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
          if (video != null)
            IconButton(
              tooltip: 'Watch in video',
              icon: const Icon(Icons.play_circle_outline_rounded),
              color: AppColors.primary,
              onPressed: () => _openVideo(context, video),
            ),
        ],
      ),
    );
  }
}
