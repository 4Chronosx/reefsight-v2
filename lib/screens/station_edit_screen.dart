import 'package:flutter/material.dart';

import '../services/app_database.dart';
import '../services/geo_fix_controller.dart';
import '../services/location_provider.dart';
import '../services/station.dart';
import '../services/station_checks.dart';
import '../widgets/geo_fix_panel.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';
import 'station_detail_screen.dart';

/// Issue #2: create or edit a TB 2019-04 station (75 × 25 m). Pops with the
/// saved station's id, or `null` if left without saving.
///
/// Survey type and frame mode are fixed for the whole station (blueprint
/// §1), so once it has a transect ([transectCount] > 0) they're shown but
/// locked -- changing them would leave transects captured the other way.
/// The deep-edge GPS fix is a surface fix taken over the marker, so unlike
/// Setup's entry fix it isn't acquired on open: the diver taps it there.
class StationEditScreen extends StatefulWidget {
  const StationEditScreen({
    super.key,
    this.existing,
    this.transectCount = 0,
    this.openDatabase = openAppDatabase,
    this.locationProvider = const GeolocatorLocationProvider(),
  });

  final Station? existing;
  final int transectCount;
  final DatabaseOpener openDatabase;
  final LocationProvider locationProvider;

  @override
  State<StationEditScreen> createState() => _StationEditScreenState();
}

class _StationEditScreenState extends State<StationEditScreen> {
  late final _code = TextEditingController(text: widget.existing?.code);
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _site = TextEditingController(text: widget.existing?.siteName);
  late final _observer = TextEditingController(text: widget.existing?.observerName);
  late final _depthMin = TextEditingController(text: _num(widget.existing?.depthMinM));
  late final _depthMax = TextEditingController(text: _num(widget.existing?.depthMaxM));
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late final GeoFixController _deepEdge;

  late SurveyType _type = widget.existing?.surveyType ?? SurveyType.photoTransect;
  late FrameMode _frameMode = widget.existing?.frameMode ?? FrameMode.physical;
  late ReefZone? _zone = widget.existing?.reefZone;
  late DateTime _date = widget.existing?.surveyedOn ?? DateTime.now();
  late bool _markerPlaced = widget.existing?.markerPlaced ?? false;
  bool _saving = false;

  bool get _locked => widget.existing != null && widget.transectCount > 0;

  static String _num(double? v) => v == null ? '' : v.toString();

  @override
  void initState() {
    super.initState();
    _deepEdge = GeoFixController(widget.locationProvider);
    final fix = widget.existing?.deepEdgeFix;
    if (fix != null) _deepEdge.setManual(fix);
    if (widget.existing == null) _prefillFromLastStation();
  }

  /// Same convenience as Setup's prefill: a failed read is dropped.
  Future<void> _prefillFromLastStation() async {
    try {
      final db = await widget.openDatabase();
      try {
        final stations = await db.listStations();
        if (stations.isEmpty || !mounted) return;
        final last = stations.first.station;
        setState(() {
          if (_site.text.isEmpty) _site.text = last.siteName ?? '';
          if (_observer.text.isEmpty) _observer.text = last.observerName ?? '';
        });
      } finally {
        await db.close();
      }
    } catch (_) {
      // Ignored -- see doc comment above.
    }
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _site, _observer, _depthMin, _depthMax, _notes]) {
      c.dispose();
    }
    _deepEdge.dispose();
    super.dispose();
  }

  static double? _parse(String text) => double.tryParse(text.trim());

  static String? _depthError(String text) {
    if (text.trim().isEmpty) return null;
    final v = _parse(text);
    return v == null || v < 0 ? 'Enter a depth in meters' : null;
  }

  String? get _minError {
    final own = _depthError(_depthMin.text);
    if (own != null) return own;
    final min = _parse(_depthMin.text);
    final max = _parse(_depthMax.text);
    return min != null && max != null && min > max ? 'Deeper than the max' : null;
  }

  String? get _maxError => _depthError(_depthMax.text);

  bool get _valid => _code.text.trim().isNotEmpty && _minError == null && _maxError == null;

  static String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final existing = widget.existing;
    final type = _locked ? existing!.surveyType : _type;
    final station = Station(
      id: existing?.id,
      code: _code.text.trim(),
      name: _text(_name),
      surveyType: type,
      frameMode: type == SurveyType.photoTransect ? (_locked ? existing!.frameMode : _frameMode) : null,
      surveyedOn: _date,
      siteName: _text(_site),
      reefZone: _zone,
      depthMinM: _parse(_depthMin.text),
      depthMaxM: _parse(_depthMax.text),
      deepEdgeFix: _deepEdge.value.fix,
      markerPlaced: _markerPlaced,
      observerName: _text(_observer),
      notes: _text(_notes),
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
    );
    try {
      final db = await widget.openDatabase();
      final int id;
      try {
        if (existing == null) {
          id = await db.insertStation(station);
        } else {
          await db.updateStation(station);
          id = existing.id!;
        }
      } finally {
        await db.close();
      }
      // Backed out while saving: this route is gone, and popping would
      // close the one underneath.
      if (!mounted) return;
      navigator.pop(id);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Saving the station failed: $error')));
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _chips<T>({
    required List<T> values,
    required T? selected,
    required String Function(T) label,
    required ValueChanged<T>? onSelected,
  }) =>
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final v in values)
            ChoiceChip(
              label: Text(label(v)),
              selected: v == selected,
              onSelected: onSelected == null ? null : (_) => onSelected(v),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final maxDepth = _parse(_depthMax.text);
    final date = _date;
    final dateText = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final type = _locked ? widget.existing!.surveyType : _type;

    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New station' : 'Edit station')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              icon: Icons.flag_outlined,
              title: 'Station',
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('station-code'),
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Station code',
                      helperText: 'e.g. ALG-S1 -- the code on the slate',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('station-name'),
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Name (optional)'),
                  ),
                  const SizedBox(height: 4),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('Survey date'),
                    subtitle: Text(dateText),
                    onTap: _pickDate,
                  ),
                  TextField(
                    key: const ValueKey('station-site'),
                    controller: _site,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Site or MPA (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('station-observer'),
                    controller: _observer,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Lead observer (optional)'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.science_outlined,
              title: 'Survey type',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _chips<SurveyType>(
                    values: SurveyType.values,
                    selected: type,
                    label: surveyTypeLabel,
                    onSelected: _locked ? null : (v) => setState(() => _type = v),
                  ),
                  const SizedBox(height: 6),
                  Text(surveyTypeHint(type), style: const TextStyle(fontSize: 12)),
                  if (type == SurveyType.photoTransect) ...[
                    const SizedBox(height: 12),
                    const Text('Frame mode', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    _chips<FrameMode>(
                      values: FrameMode.values,
                      selected: _locked ? widget.existing!.frameMode : _frameMode,
                      label: frameModeLabel,
                      onSelected: _locked ? null : (v) => setState(() => _frameMode = v),
                    ),
                  ],
                  if (_locked) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Locked: this station already has transects, and all of them '
                      'must use the same survey type and frame mode.',
                      style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.waves_outlined,
              title: 'Reef zone and depth',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _chips<ReefZone>(
                    values: ReefZone.values,
                    selected: _zone,
                    label: reefZoneLabel,
                    // Tapping the selected zone again clears it.
                    onSelected: (v) => setState(() => _zone = _zone == v ? null : v),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('depth-min'),
                          controller: _depthMin,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Min depth (m)',
                            errorText: _minError,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('depth-max'),
                          controller: _depthMax,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Max depth (m)',
                            errorText: _maxError,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  if (_maxError == null && depthOverLimit(maxDepth)) ...[
                    const SizedBox(height: 8),
                    const FlagLine(kFlagStationTooDeep),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.location_on_outlined,
              title: 'Deep-edge position',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Surface GPS fix over the station\'s deeper edge, so it can be found again.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  GeoFixPanel(controller: _deepEdge),
                  SwitchListTile(
                    key: const ValueKey('marker-placed'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Concrete-block marker placed'),
                    value: _markerPlaced,
                    onChanged: (v) => setState(() => _markerPlaced = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.notes_outlined,
              title: 'Notes',
              child: TextField(
                key: const ValueKey('station-notes'),
                controller: _notes,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
            ),
            const SizedBox(height: 24),
            GloveButton(
              label: 'Save station',
              onPressed: _valid && !_saving ? _save : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A TB 2019-04 warning line: amber, never blocking. Shared by the station
/// screens.
class FlagLine extends StatelessWidget {
  const FlagLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      );
}

/// New station, then straight into it. Used by the shell's centre action and
/// the Surveys tab.
Future<void> createStation(BuildContext context, {DatabaseOpener openDatabase = openAppDatabase}) async {
  final navigator = Navigator.of(context);
  final id = await navigator.push<int>(
    MaterialPageRoute(builder: (_) => StationEditScreen(openDatabase: openDatabase)),
  );
  if (id == null) return;
  await navigator.push<void>(StationDetailScreen.route(id, openDatabase));
}
