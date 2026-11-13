import 'dart:math';

import 'package:flutter/material.dart';

import '../services/app_database.dart';
import '../services/device_health_monitor.dart';
import '../services/device_info.dart';
import '../services/geo_fix_controller.dart';
import '../services/location_provider.dart';
import '../services/station.dart';
import '../services/station_checks.dart';
import '../services/transect_placement.dart';
import '../services/transect_session.dart';
import '../widgets/geo_fix_panel.dart';
import '../widgets/glove_button.dart';
import '../widgets/ready_to_dive_card.dart';
import '../widgets/section_card.dart';
import 'capture_placeholder_screen.dart';
import 'station_edit_screen.dart' show FlagLine;
import 'transect_setup_screen.dart';

/// What a photo or preliminary transect's capture flow is handed: the row
/// Setup just saved.
class CaptureStart {
  const CaptureStart({required this.station, required this.sessionId, required this.transectNumber});

  final Station station;
  final int sessionId;
  final int transectNumber;
}

typedef OpenCapture = void Function(BuildContext context, CaptureStart start);

/// The real [OpenCapture] until #4 and #13 land. Replaces Setup, so the
/// back button returns to the station rather than to a form whose transect
/// is already saved.
void pushCapturePlaceholder(BuildContext context, CaptureStart start) {
  Navigator.of(context).pushReplacement(
    MaterialPageRoute(
      builder: (_) => CapturePlaceholderScreen(
        station: start.station,
        sessionId: start.sessionId,
        transectNumber: start.transectNumber,
      ),
    ),
  );
}

/// CPCe's 10 points per frame (TB 2017-05), for photo and preliminary.
const kPointsPerFrame = 10;

/// Issue #2: set up one transect (T1-T5) of a station -- number, tape,
/// depth at each end and TB 2019-04's random placement -- then route by the
/// station's survey type:
///
/// - **Colony count**: the existing Live flow ([startTransect]); Live
///   inserts the session, now with the station fields ([TransectPlacement]).
/// - **Photo transect / Preliminary**: the transect row is inserted here
///   and handed to its capture flow ([openCapture]), so #4 and #13 attach
///   frames to a real session.
///
/// Site and observer come from the station. The entry fix and "Ready to
/// dive" checks are the same as the quick transect Setup's.
class StationTransectSetupScreen extends StatefulWidget {
  const StationTransectSetupScreen({
    super.key,
    required this.station,
    this.openDatabase = openAppDatabase,
    this.storageInfo = const PlatformDeviceInfo(),
    this.batteryInfo = const BatteryPlusInfo(),
    this.thermalInfo = const PlatformDeviceInfo(),
    this.locationProvider = const GeolocatorLocationProvider(),
    this.startTransect = pushLiveTransect,
    this.openCapture = pushCapturePlaceholder,
    this.random,
  });

  final Station station;
  final DatabaseOpener openDatabase;
  final StorageInfo storageInfo;
  final BatteryInfo batteryInfo;
  final ThermalInfo thermalInfo;
  final LocationProvider locationProvider;
  final StartTransect startTransect;
  final OpenCapture openCapture;

  /// The placement generator's source; seeded in tests.
  final Random? random;

  @override
  State<StationTransectSetupScreen> createState() => _StationTransectSetupScreenState();
}

class _StationTransectSetupScreenState extends State<StationTransectSetupScreen> {
  final _tape = TextEditingController(text: '50');
  final _depthStart = TextEditingController();
  final _depthEnd = TextEditingController();
  final _along = TextEditingController();
  final _swimout = TextEditingController();
  late final Random _random = widget.random ?? Random();
  late final DeviceHealthMonitor _deviceHealth;
  late final GeoFixController _entryFix;

  Set<int> _used = const {};
  int? _number;
  bool _loaded = false;
  bool _loadFailed = false;
  bool _starting = false;
  bool _recountPlanned = false;

  Station get _station => widget.station;
  bool get _colonyCount => _station.surveyType == SurveyType.colonyCount;

  @override
  void initState() {
    super.initState();
    _loadNumbers();
    _entryFix = GeoFixController(widget.locationProvider)..acquire();
    _deviceHealth = DeviceHealthMonitor(
      storage: widget.storageInfo,
      battery: widget.batteryInfo,
      thermal: widget.thermalInfo,
      pollInterval: const Duration(seconds: 30),
    )..start();
  }

  /// Reads the numbers already used. Keeps the diver's chosen number if it's
  /// still free, so a refresh doesn't silently switch T-numbers. Returns
  /// whether the read worked.
  Future<bool> _loadNumbers() async {
    try {
      final db = await widget.openDatabase();
      try {
        final transects = await db.transectsForStation(_station.id!);
        final next = await db.nextTransectNumber(_station.id!);
        final used = {for (final t in transects) ?t.transectNumber};
        if (!mounted) return true;
        setState(() {
          final current = _number;
          _used = used;
          _number = current != null && !used.contains(current)
              ? current
              : defaultTransectNumber(used, next);
          _loaded = true;
          _loadFailed = false;
        });
        return true;
      } finally {
        await db.close();
      }
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _loaded = true;
        _loadFailed = true;
      });
      return false;
    }
  }

  @override
  void dispose() {
    _deviceHealth.dispose();
    _entryFix.dispose();
    for (final c in [_tape, _depthStart, _depthEnd, _along, _swimout]) {
      c.dispose();
    }
    super.dispose();
  }

  static double? _parse(TextEditingController c) => double.tryParse(c.text.trim());

  double? get _tapeM => _parse(_tape);

  String? get _tapeError {
    final v = _tapeM;
    return v == null || v <= 0 ? 'Enter a positive number' : null;
  }

  static String? _depthError(TextEditingController c) {
    if (c.text.trim().isEmpty) return null;
    final v = _parse(c);
    return v == null || v < 0 ? 'Enter a depth in meters' : null;
  }

  bool get _valid =>
      _number != null &&
      _tapeError == null &&
      _depthError(_depthStart) == null &&
      _depthError(_depthEnd) == null &&
      alongError(_along.text) == null &&
      swimoutError(_swimout.text) == null;

  void _generate() {
    final p = generateRandomPlacement(_random);
    setState(() {
      _along.text = p.alongM.toString();
      _swimout.text = p.swimoutM.toString();
    });
  }

  CaptureSource get _captureSource => switch (_station.surveyType) {
        SurveyType.colonyCount => CaptureSource.legacyColony,
        SurveyType.preliminaryVideo => CaptureSource.inAppVideo,
        SurveyType.photoTransect => _station.frameMode == FrameMode.importedMixed
            ? CaptureSource.importedPhotos
            : CaptureSource.inAppPhotos,
      };

  TransectPlacement _placement() => TransectPlacement(
        stationId: _station.id!,
        transectNumber: _number!,
        captureSource: _captureSource,
        depthStartM: _parse(_depthStart),
        depthEndM: _parse(_depthEnd),
        randomAlongM: _parse(_along),
        randomSwimoutM: _parse(_swimout),
      );

  Future<void> _start() async {
    if (!_valid || _starting) return;
    setState(() => _starting = true);
    final messenger = ScaffoldMessenger.of(context);
    final chosen = _number!;

    // Re-read first: a transect may have taken this number since the screen
    // opened (e.g. a Live left with back). Colony count matters most -- Live
    // inserts the row and keeps recording if that insert fails.
    final fresh = await _loadNumbers();
    if (!mounted) return;
    if (!fresh || _used.contains(chosen)) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            fresh ? 'T$chosen is already taken. Pick another number.' : 'Could not check the numbers.',
          ),
        ),
      );
      setState(() => _starting = false);
      return;
    }

    final placement = _placement();
    if (_colonyCount) {
      await widget.startTransect(
        context,
        TransectStart(
          tapeLengthMeters: _tapeM!,
          siteName: _station.siteName,
          observerName: _station.observerName,
          entryFix: _entryFix.value.fix,
          resultsHidden: _recountPlanned,
          placement: placement,
        ),
      );
      // Back from Live (if this screen is still there): the number is now
      // used, so refresh before another Start.
      if (!mounted) return;
      await _loadNumbers();
      if (mounted) setState(() => _starting = false);
      return;
    }

    try {
      final db = await widget.openDatabase();
      final int sessionId;
      try {
        sessionId = await db.insertSession(
          placement.applyTo(
            TransectSession(
              startedAt: DateTime.now().toUtc(),
              tapeLengthMeters: _tapeM!,
              siteName: _station.siteName,
              observerName: _station.observerName,
              entryFix: _entryFix.value.fix,
              pointsPerFrame: kPointsPerFrame,
            ),
          ),
        );
      } finally {
        await db.close();
      }
      if (!mounted) return;
      widget.openCapture(
        context,
        CaptureStart(station: _station, sessionId: sessionId, transectNumber: placement.transectNumber),
      );
    } catch (error) {
      // Most likely the unique (station, number) index: another transect
      // took this number since the screen opened.
      messenger.showSnackBar(SnackBar(content: Text('Could not save T$chosen: $error')));
      if (mounted) setState(() => _starting = false);
      _loadNumbers();
    }
  }

  String get _startLabel => switch (_station.surveyType) {
        SurveyType.colonyCount => 'Start Transect',
        SurveyType.photoTransect => 'Start photo capture',
        SurveyType.preliminaryVideo => 'Start video capture',
      };

  TextField _numberField(String key, TextEditingController c, String label, String? error) =>
      TextField(
        key: ValueKey(key),
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, errorText: error),
        onChanged: (_) => setState(() {}),
      );

  @override
  Widget build(BuildContext context) {
    final tape = _tapeM;
    final tooDeep = (_depthError(_depthStart) == null && depthOverLimit(_parse(_depthStart))) ||
        (_depthError(_depthEnd) == null && depthOverLimit(_parse(_depthEnd)));

    return Scaffold(
      appBar: AppBar(title: Text('${_station.code} · new transect')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              icon: Icons.tag_rounded,
              title: 'Transect number',
              child: !_loaded
                  ? const LinearProgressIndicator()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          children: [
                            for (var n = 1; n <= kMaxTransects; n++)
                              ChoiceChip(
                                key: ValueKey('transect-number-$n'),
                                label: Text('T$n'),
                                selected: _number == n,
                                onSelected:
                                    _used.contains(n) ? null : (_) => setState(() => _number = n),
                              ),
                          ],
                        ),
                        if (_loadFailed) ...[
                          const SizedBox(height: 8),
                          const Text(
                            "Could not read this station's transects.",
                            style: TextStyle(fontSize: 13),
                          ),
                          TextButton(onPressed: _loadNumbers, child: const Text('Retry')),
                        ] else if (_number == null) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'All five transects of this station are set up.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.straighten_rounded,
              title: 'Tape and depth',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in kTapeLengthPresetsMeters)
                        ChoiceChip(
                          label: Text('$preset m'),
                          selected: _tape.text == preset.toString(),
                          onSelected: (_) => setState(() => _tape.text = preset.toString()),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('tape-length'),
                    controller: _tape,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Tape length (meters)',
                      errorText: _tapeError,
                      helperText: _tapeError == null && tape != null && tapeNotStandard(tape)
                          ? 'Not the standard 50 m tape (TB 2019-04)'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _numberField(
                          'depth-start',
                          _depthStart,
                          'Depth at start (m)',
                          _depthError(_depthStart),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _numberField(
                          'depth-end',
                          _depthEnd,
                          'Depth at end (m)',
                          _depthError(_depthEnd),
                        ),
                      ),
                    ],
                  ),
                  if (tooDeep) ...[
                    const SizedBox(height: 8),
                    const FlagLine(kFlagTransectTooDeep),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.casino_outlined,
              title: 'Random placement',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TB 2019-04 Fig. 3: a random distance along the 75 m axis, then a '
                    'random 0-25 m swim-out. Generate here or enter numbers drawn on the boat.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _numberField(
                          'random-along',
                          _along,
                          'Along axis (0-75 m)',
                          alongError(_along.text),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _numberField(
                          'random-swimout',
                          _swimout,
                          'Swim-out (0-25 m)',
                          swimoutError(_swimout.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('generate-placement'),
                    onPressed: _generate,
                    icon: const Icon(Icons.casino_outlined),
                    label: const Text('Generate'),
                  ),
                ],
              ),
            ),
            if (_colonyCount) ...[
              const SizedBox(height: 16),
              SectionCard(
                icon: Icons.badge_outlined,
                title: 'Recount',
                child: SwitchListTile(
                  key: const ValueKey('recount-planned'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Recount planned'),
                  subtitle: const Text(
                    "Hide the app's results until the manual recount is entered.",
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _recountPlanned,
                  onChanged: (value) => setState(() => _recountPlanned = value),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.location_on_outlined,
              title: 'Entry position',
              child: GeoFixPanel(controller: _entryFix),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<DeviceHealth?>(
              valueListenable: _deviceHealth.health,
              builder: (context, health, _) => ValueListenableBuilder<GeoFixState>(
                valueListenable: _entryFix,
                builder: (context, entry, _) => ReadyToDiveCard(
                  health: health,
                  entryPosition: entryPositionCheck(entry),
                ),
              ),
            ),
            const SizedBox(height: 24),
            GloveButton(label: _startLabel, onPressed: _valid && !_starting ? _start : null),
          ],
        ),
      ),
    );
  }
}
