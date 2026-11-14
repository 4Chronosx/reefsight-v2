import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/coreml_benchmark.dart';
import '../services/device_info.dart';
import '../services/screen_awake.dart';
import '../widgets/section_card.dart';

/// Issue #11: the Core ML speed test for the CoralscapesV2 SegFormer.
/// Dev-only, from Settings → Diagnostics. Load the notebook's
/// `coralscapes_bench_<RUN_ID>.zip` (AirDrop → Files), run the matrix and the
/// sustained test, then share the results folder back to the laptop.
/// Method and thresholds: `docs/coralscapes-coreml-speed-test.md`.
class CoreMlBenchmarkScreen extends StatefulWidget {
  const CoreMlBenchmarkScreen({
    super.key,
    this.bench = const NativeCoreMlBench(),
    this.thermal = const PlatformDeviceInfo(),
    this.battery = const BatteryPlusInfo(),
    this.screenAwake = const WakelockScreenAwake(),
    this.pickPackage = pickBenchPackage,
    this.workDir = benchWorkDir,
    this.shareResults = shareBenchResults,
    this.deviceLabel = benchDeviceLabel,
  });

  final CoreMlBench bench;
  final ThermalInfo thermal;
  final BatteryInfo battery;
  final ScreenAwake screenAwake;
  final Future<String?> Function() pickPackage;
  final Future<Directory> Function() workDir;
  final Future<void> Function(Directory results) shareResults;
  final Future<String> Function(CoreMlBench bench) deviceLabel;

  @override
  State<CoreMlBenchmarkScreen> createState() => _CoreMlBenchmarkScreenState();
}

/// The zip through the Files app (`FileType.custom`, as `photo_source.dart`).
Future<String?> pickBenchPackage() async {
  final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);
  return result?.files.singleOrNull?.path;
}

/// Application Support, not Documents: the ~340 MB package and the compiled
/// models are scratch data, and Documents is backed up to iCloud.
Future<Directory> benchWorkDir() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'coreml_bench'));

/// E.g. "iPhone14,7 / ios Version 26.1 (Build ...)": the hardware model proves
/// which phone produced the numbers.
Future<String> benchDeviceLabel(CoreMlBench bench) async {
  String? model;
  try {
    model = await bench.deviceModel();
  } catch (_) {}
  return '${model ?? 'unknown model'} / ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
}

/// Zips the results folder and opens the share sheet, then deletes the zip.
Future<void> shareBenchResults(Directory results) async {
  final zipPath = p.join(Directory.systemTemp.path, '${p.basename(results.path)}_results.zip');
  try {
    await ZipFileEncoder().zipDirectory(results, filename: zipPath);
    await Share.shareXFiles(
      [XFile(zipPath, mimeType: 'application/zip')],
      subject: 'ReefSight Core ML benchmark results',
    );
  } finally {
    final zip = File(zipPath);
    if (zip.existsSync()) await zip.delete();
  }
}

class _CoreMlBenchmarkScreenState extends State<CoreMlBenchmarkScreen> {
  BenchPackage? _package;
  BenchmarkRunner? _runner;
  Directory? _outDir;
  String? _error;
  String? _busy;
  bool _stop = false;
  final _log = <String>[];
  final _arms = <ArmResult>[];
  final _sustained = <SustainedResult>[];
  SustainedSample? _lastSample;

  BenchModel? _sustainedModel;
  ComputeUnits _sustainedUnits = ComputeUnits.cpuAndNeuralEngine;
  int _sustainedMinutes = 20;

  /// Leaving the screen stops a run at its next check, rather than leaving a
  /// 20 min inference loop running out of sight.
  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final zip = await widget.pickPackage();
      if (zip == null || !mounted) return;
      setState(() => _busy = 'Unzipping…');
      final work = await widget.workDir();
      final package = await extractBenchPackage(zip, Directory(p.join(work.path, 'packages')));
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final out = Directory(p.join(work.path, 'results', '${package.manifest.runId}_$stamp'));
      setState(() {
        _package = package;
        _outDir = out;
        _sustainedModel = package.manifest.models.last;
        _arms.clear();
        _sustained.clear();
        _log.clear();
        _runner = BenchmarkRunner(
          bench: widget.bench,
          package: package,
          outDir: out,
          thermal: widget.thermal,
          battery: widget.battery,
          onLog: (line) {
            if (mounted) setState(() => _log.add(line));
          },
        );
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _writeReport(BenchmarkRunner runner) async => runner.writeReport(
    arms: _arms,
    sustained: _sustained,
    device: await widget.deviceLabel(widget.bench),
  );

  /// Keeps the screen awake for a run, and writes the report after it.
  Future<void> _run(String label, Future<void> Function(BenchmarkRunner runner) body) async {
    final runner = _runner;
    if (runner == null) return;
    setState(() {
      _busy = label;
      _stop = false;
      _error = null;
    });
    final lease = ScreenAwakeLease(widget.screenAwake)..acquire();
    try {
      await body(runner);
      await _writeReport(runner);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      lease.release();
      if (mounted) setState(() => _busy = null);
    }
  }

  /// A new matrix replaces the previous one's arms. Each arm is saved as it
  /// finishes, so a run the OS kills (memory, heat) keeps what it measured.
  Future<void> _runMatrix() => _run('Running the matrix…', (runner) async {
    setState(_arms.clear);
    await runner.runMatrix(
      shouldStop: () => _stop,
      onArm: (arm) async {
        _arms.add(arm);
        if (mounted) setState(() {});
        await _writeReport(runner);
      },
    );
  });

  Future<void> _runSustained() => _run('Sustained test…', (runner) async {
    final result = await runner.runSustained(
      _sustainedModel!,
      _sustainedUnits,
      duration: Duration(minutes: _sustainedMinutes),
      shouldStop: () => _stop,
      onSample: (s) {
        if (mounted) setState(() => _lastSample = s);
      },
    );
    if (mounted) setState(() => _sustained.add(result));
  });

  @override
  Widget build(BuildContext context) {
    final package = _package;
    final busy = _busy != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Core ML benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            icon: Icons.inventory_2_outlined,
            title: 'Benchmark package',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Load coralscapes_bench_<RUN_ID>.zip from notebook 29 (AirDrop it to Files first). '
                  'Keep the phone out of a case and off the charger while it runs.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                if (package != null)
                  Text(
                    key: const Key('bench-summary'),
                    'Run ${package.manifest.runId}: ${package.manifest.models.length} models, '
                    '${package.manifest.samples.length} sample${package.manifest.samples.length == 1 ? '' : 's'} '
                    '(${package.manifest.models.map((m) => m.name).join(', ')})',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(fontSize: 13, color: Colors.redAccent)),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('bench-load'),
                  onPressed: busy ? null : _load,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load package'),
                ),
              ],
            ),
          ),
          if (package != null) ...[
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.speed,
              title: 'Latency matrix',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Every model on CPU + Neural Engine, All, and CPU + GPU: 3 warm-up runs '
                    '(which also write the class maps), then 30 timed runs.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('bench-run-matrix'),
                    onPressed: busy ? null : _runMatrix,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Run matrix'),
                  ),
                  for (final arm in _arms) _ArmTile(arm),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              icon: Icons.thermostat,
              title: 'Sustained (heat and battery)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'One inference every 1.5 s, the preliminary mode\'s rate.',
                    style: TextStyle(fontSize: 13),
                  ),
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<BenchModel>(
                        value: _sustainedModel,
                        onChanged: busy ? null : (m) => setState(() => _sustainedModel = m),
                        items: [
                          for (final m in package.manifest.models) DropdownMenuItem(value: m, child: Text(m.name)),
                        ],
                      ),
                      DropdownButton<ComputeUnits>(
                        value: _sustainedUnits,
                        onChanged: busy ? null : (u) => setState(() => _sustainedUnits = u!),
                        items: [
                          for (final u in ComputeUnits.values) DropdownMenuItem(value: u, child: Text(u.label)),
                        ],
                      ),
                      DropdownButton<int>(
                        value: _sustainedMinutes,
                        onChanged: busy ? null : (m) => setState(() => _sustainedMinutes = m!),
                        items: [
                          for (final m in const [1, 5, 20, 30]) DropdownMenuItem(value: m, child: Text('$m min')),
                        ],
                      ),
                    ],
                  ),
                  FilledButton.icon(
                    key: const Key('bench-run-sustained'),
                    onPressed: busy ? null : _runSustained,
                    icon: const Icon(Icons.timer_outlined),
                    label: const Text('Start sustained test'),
                  ),
                  if (_busy == 'Sustained test…' && _lastSample != null)
                    Text(
                      '${_lastSample!.tSeconds.toStringAsFixed(0)} s: ${_lastSample!.ms.toStringAsFixed(0)} ms, '
                      'heat ${_lastSample!.thermal?.name ?? '-'}, battery ${_lastSample!.batteryPercent ?? '-'} %',
                      style: const TextStyle(fontSize: 13),
                    ),
                  for (final s in _sustained)
                    Text(
                      '${s.model} · ${s.units.label}: ${s.samples.length} runs, peak heat '
                      '${s.peakThermal?.name ?? '-'}, battery ${s.batteryStart ?? '-'} → ${s.batteryEnd ?? '-'} %'
                      '${s.stoppedEarly ? ' (stopped)' : ''}${s.error != null ? ' — FAILED: ${s.error}' : ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (busy) ...[
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_busy!)),
                  TextButton(
                    key: const Key('bench-stop'),
                    onPressed: _stop ? null : () => setState(() => _stop = true),
                    child: Text(_stop ? 'Stopping…' : 'Stop'),
                  ),
                ] else
                  OutlinedButton.icon(
                    key: const Key('bench-share'),
                    onPressed: _arms.isEmpty && _sustained.isEmpty ? null : () => widget.shareResults(_outDir!),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share results'),
                  ),
              ],
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_log.join('\n'), style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ],
          ] else if (busy)
            Padding(padding: const EdgeInsets.only(top: 16), child: Text(_busy!)),
        ],
      ),
    );
  }
}

class _ArmTile extends StatelessWidget {
  const _ArmTile(this.arm);

  final ArmResult arm;

  @override
  Widget build(BuildContext context) {
    final s = arm.stats;
    final plan = arm.plan;
    final mb = arm.footprintPeakBytes == null ? '-' : '${(arm.footprintPeakBytes! / 1e6).round()} MB';
    return ListTile(
      key: const Key('bench-arm'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text('${arm.model} · ${arm.units.label}'),
      subtitle: Text(
        arm.error != null
            ? 'FAILED: ${arm.error}'
            : s == null
            ? 'No timed runs'
            : 'median ${s.median.toStringAsFixed(0)} ms, p90 ${s.p90.toStringAsFixed(0)} ms per window · '
                  '${(arm.perPhotoMedianMs! / 1000).toStringAsFixed(1)} s per photo · peak $mb'
                  '${plan != null && plan.available ? ' · ${(plan.neuralEngineShare * 100).round()}% Neural Engine' : ''}',
        style: TextStyle(color: arm.error != null ? Colors.redAccent : null),
      ),
    );
  }
}
