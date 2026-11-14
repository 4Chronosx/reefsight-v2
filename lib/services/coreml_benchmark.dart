import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'device_checks.dart';
import 'device_info.dart';

/// Issue #11: the iPhone 14 speed test for the CoralscapesV2 SegFormer
/// (`EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024`), run before
/// the Core ML bridge (#12) is built. Dev-only, reached from Settings.
///
/// Round trip (docs/coralscapes-coreml-speed-test.md):
/// 1. `machine-learning-pipeline/notebooks/29_coralscapes_coreml_export.ipynb`
///    converts the model (1024 and 512 input, optionally int8 weights) and packs
///    `coralscapes_bench_<RUN_ID>.zip`: the `.mlpackage`s, sample windows and
///    `bench_manifest.json`. It is AirDropped to the phone, not bundled.
/// 2. The phone compiles each model, records where its ops run, times it on
///    each compute-unit setting, runs a sustained test for heat and battery,
///    and writes `bench_results.json` plus the class maps of the samples.
/// 3. The notebook's second section reads that back and compares the phone's
///    maps with PyTorch's: conversion fidelity, and what 512 input loses.
///
/// Inference itself is native (`AppDelegate.swift`, `reefsight/coreml_bench`);
/// everything else is here, so it can be tested off-device.

const kBenchFormat = 'reefsight-coreml-bench';
const kBenchResultsFormat = 'reefsight-coreml-bench-results';
const kBenchVersion = 1;
const kBenchManifestName = 'bench_manifest.json';

/// `MLComputeUnits`, by the name the Swift side switches on.
enum ComputeUnits {
  cpuAndNeuralEngine,
  all,
  cpuAndGpu,
  cpuOnly;

  String get label => switch (this) {
    cpuAndNeuralEngine => 'CPU + Neural Engine',
    all => 'All (CPU, GPU, Neural Engine)',
    cpuAndGpu => 'CPU + GPU',
    cpuOnly => 'CPU only',
  };
}

/// A relative path that stays inside the package: no root, no `..`.
bool isSafeRelativePath(String path) {
  if (path.isEmpty || path.contains('\\') || p.posix.isAbsolute(path)) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return false;
  return !p.posix.split(path).contains('..');
}

String _safePath(Object? raw, String what) {
  if (raw is! String || !isSafeRelativePath(raw)) {
    throw FormatException('$what is not a safe relative path: $raw');
  }
  return raw;
}

class BenchModel {
  const BenchModel({
    required this.name,
    required this.path,
    required this.inputSize,
    required this.weights,
    required this.windowsPerPhoto,
  });

  factory BenchModel.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final size = json['input_size'];
    final windows = json['windows_per_photo'];
    if (name is! String || !RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(name)) {
      throw FormatException('Bad model name: $name');
    }
    if (size is! int || size <= 0) throw FormatException('Bad input_size for $name: $size');
    if (windows is! int || windows <= 0) {
      throw FormatException('Bad windows_per_photo for $name: $windows');
    }
    return BenchModel(
      name: name,
      path: _safePath(json['path'], 'Model $name path'),
      inputSize: size,
      weights: json['weights'] as String? ?? 'fp16',
      windowsPerPhoto: windows,
    );
  }

  final String name;

  /// The `.mlpackage`, relative to the package root.
  final String path;

  /// Square input side in pixels (1024 or 512).
  final int inputSize;

  /// `fp16`, or `w8` for int8 weights.
  final String weights;

  /// Sliding windows one photo needs under the model card's recipe (short
  /// side resized to [inputSize], windows of [inputSize]²): 2 for a 4:3 photo.
  final int windowsPerPhoto;
}

class BenchSample {
  const BenchSample({required this.id, required this.inputs});

  final String id;

  /// Input side → PNG of exactly that size, relative to the package root.
  final Map<int, String> inputs;

  String inputFor(int size) => inputs[size]!;
}

class BenchManifest {
  const BenchManifest({
    required this.runId,
    required this.hfModel,
    required this.hfRevision,
    required this.numClasses,
    required this.models,
    required this.samples,
  });

  factory BenchManifest.fromJson(Map<String, Object?> json) {
    if (json['format'] != kBenchFormat) {
      throw FormatException('Not a ReefSight Core ML benchmark package: ${json['format']}');
    }
    if (json['version'] != kBenchVersion) {
      throw FormatException('Benchmark package version ${json['version']}; this app reads $kBenchVersion');
    }
    final models = [
      for (final m in (json['models'] as List? ?? const []).cast<Map>())
        BenchModel.fromJson(m.cast<String, Object?>()),
    ];
    if (models.isEmpty) throw const FormatException('The package lists no models');
    final samples = <BenchSample>[];
    for (final s in (json['samples'] as List? ?? const []).cast<Map>()) {
      final id = s['id'];
      if (id is! String || !RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id)) {
        throw FormatException('Bad sample id: $id');
      }
      final inputs = <int, String>{
        for (final e in (s['inputs'] as Map? ?? const {}).entries)
          int.parse(e.key as String): _safePath(e.value, 'Sample $id input'),
      };
      for (final m in models) {
        if (!inputs.containsKey(m.inputSize)) {
          throw FormatException('Sample $id has no ${m.inputSize} input for ${m.name}');
        }
      }
      samples.add(BenchSample(id: id, inputs: inputs));
    }
    if (samples.isEmpty) throw const FormatException('The package lists no samples');
    final runId = json['run_id'];
    // Names folders on the phone, so it must be a plain name.
    if (runId is! String || !_safeName.hasMatch(runId)) throw FormatException('Bad run_id: $runId');
    return BenchManifest(
      runId: runId,
      hfModel: json['hf_model'] as String? ?? '',
      hfRevision: json['hf_revision'] as String? ?? '',
      numClasses: json['num_classes'] as int? ?? 0,
      models: models,
      samples: samples,
    );
  }

  final String runId;
  final String hfModel;
  final String hfRevision;
  final int numClasses;
  final List<BenchModel> models;
  final List<BenchSample> samples;

  /// Smallest input first, then int8 weights before FP16: the order of
  /// least compute and memory.
  List<BenchModel> get lightestFirst => [...models]
    ..sort((a, b) {
      final bySize = a.inputSize.compareTo(b.inputSize);
      if (bySize != 0) return bySize;
      return (a.weights == 'w8' ? 0 : 1).compareTo(b.weights == 'w8' ? 0 : 1);
    });
}

/// An unzipped benchmark package: the folder holding `bench_manifest.json`.
class BenchPackage {
  const BenchPackage({required this.root, required this.manifest});

  final Directory root;
  final BenchManifest manifest;

  String resolve(String relative) => p.joinAll([root.path, ...p.posix.split(relative)]);
}

/// `archive` inflates each entry into memory, so one entry (a model's weights,
/// ~170 MB at FP16) must stay well under the app's memory limit.
const kMaxBenchEntryBytes = 1024 * 1024 * 1024;
const kMaxBenchTotalBytes = 3 * 1024 * 1024 * 1024;
const kMaxBenchManifestBytes = 1024 * 1024;

final _safeName = RegExp(r'^[A-Za-z0-9_\-]+$');

/// Unzips [zipPath] into `<packagesDir>/<run_id>/` and reads its manifest.
///
/// Every entry is checked before anything is written: a path that leaves the
/// folder, a symbolic link, or an oversized entry refuses the whole package
/// (archive's own `extractArchiveToDisk` skips bad entries silently and
/// swallows write errors, so it isn't used). It unzips into a temporary
/// folder and renames it only on success, so a failure leaves nothing
/// half-written and an earlier copy of the same run is replaced only by a
/// complete one. The folder is named by the manifest's validated `run_id`,
/// never by the zip's file name. The manifest may sit at the top or one
/// folder down, as the notebook writes it.
Future<BenchPackage> extractBenchPackage(String zipPath, Directory packagesDir) async {
  final input = InputFileStream(zipPath);
  Directory? tmp;
  try {
    final archive = ZipDecoder().decodeStream(input);
    ArchiveFile? manifestEntry;
    var total = 0;
    for (final entry in archive) {
      if (!isSafeRelativePath(entry.name)) {
        throw FormatException('Unsafe path in benchmark package: ${entry.name}');
      }
      if (entry.isSymbolicLink) {
        throw FormatException('Symbolic link in benchmark package: ${entry.name}');
      }
      if (entry.size > kMaxBenchEntryBytes) {
        throw FormatException('${entry.name} is too large for a benchmark package (${entry.size} bytes)');
      }
      total += entry.size;
      if (total > kMaxBenchTotalBytes) {
        throw const FormatException('The benchmark package is too large to unzip on the phone');
      }
      final parts = p.posix.split(entry.name);
      if (entry.isFile && parts.last == kBenchManifestName && parts.length <= 2) {
        if (manifestEntry != null) {
          throw const FormatException('The package holds more than one $kBenchManifestName');
        }
        manifestEntry = entry;
      }
    }
    if (manifestEntry == null) {
      throw const FormatException('No $kBenchManifestName in this zip; is it a benchmark package?');
    }
    if (manifestEntry.size > kMaxBenchManifestBytes) {
      throw const FormatException('$kBenchManifestName is too large');
    }
    final manifest = BenchManifest.fromJson(
      (jsonDecode(utf8.decode(manifestEntry.content)) as Map).cast<String, Object?>(),
    );

    await packagesDir.create(recursive: true);
    tmp = await packagesDir.createTemp('.unzip_');
    for (final entry in archive) {
      final target = p.joinAll([tmp.path, ...p.posix.split(entry.name)]);
      if (!entry.isFile) {
        await Directory(target).create(recursive: true);
        continue;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      final out = OutputFileStream(target);
      try {
        entry.writeContent(out);
      } finally {
        await out.close();
      }
    }
    final dest = Directory(p.join(packagesDir.path, manifest.runId));
    if (dest.existsSync()) await dest.delete(recursive: true);
    await tmp.rename(dest.path);
    tmp = null;
    final parent = p.posix.dirname(manifestEntry.name);
    final root = parent == '.' ? dest : Directory(p.joinAll([dest.path, ...p.posix.split(parent)]));
    return BenchPackage(root: root, manifest: manifest);
  } finally {
    await input.close();
    if (tmp != null && tmp.existsSync()) await tmp.delete(recursive: true);
  }
}

class LatencyStats {
  const LatencyStats({
    required this.n,
    required this.min,
    required this.median,
    required this.p90,
    required this.mean,
    required this.max,
  });

  /// p90 is nearest-rank: the smallest value with at least 90% at or below it.
  factory LatencyStats.of(List<double> values) {
    if (values.isEmpty) throw ArgumentError.value(values, 'values', 'No latencies to summarize');
    final s = [...values]..sort();
    final n = s.length;
    final median = n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
    final p90 = s[math.max(0, (0.9 * n).ceil() - 1)];
    return LatencyStats(
      n: n,
      min: s.first,
      median: median,
      p90: p90,
      mean: s.reduce((a, b) => a + b) / n,
      max: s.last,
    );
  }

  final int n;
  final double min;
  final double median;
  final double p90;
  final double mean;
  final double max;

  Map<String, Object> toJson() => {
    'n': n,
    'min': min,
    'median': median,
    'p90': p90,
    'mean': mean,
    'max': max,
  };
}

/// Where the compiled model's ops are planned to run (`MLComputePlan`,
/// iOS 17.4+): the stand-in for Xcode's performance report, which needs a Mac.
class ComputePlanSummary {
  const ComputePlanSummary({
    required this.available,
    this.neuralEngine = 0,
    this.gpu = 0,
    this.cpu = 0,
    this.other = 0,
  });

  factory ComputePlanSummary.fromChannel(Map<Object?, Object?>? reply) {
    if (reply == null || reply['available'] != true) {
      return const ComputePlanSummary(available: false);
    }
    int count(String key) => (reply[key] as num?)?.toInt() ?? 0;
    return ComputePlanSummary(
      available: true,
      neuralEngine: count('neuralEngine'),
      gpu: count('gpu'),
      cpu: count('cpu'),
      other: count('other'),
    );
  }

  final bool available;
  final int neuralEngine;
  final int gpu;
  final int cpu;

  /// Ops with no device usage (constants and the like).
  final int other;

  int get total => neuralEngine + gpu + cpu + other;
  double get neuralEngineShare => total == 0 ? 0 : neuralEngine / total;

  Map<String, Object> toJson() => {
    'available': available,
    'neural_engine_ops': neuralEngine,
    'gpu_ops': gpu,
    'cpu_ops': cpu,
    'other_ops': other,
  };
}

class CompileResult {
  const CompileResult({required this.compiledPath, required this.compileMs});

  final String compiledPath;
  final double compileMs;
}

class LoadResult {
  const LoadResult({required this.handle, required this.loadMs, this.peakFootprintBytes});

  final int handle;
  final double loadMs;

  /// Highest `phys_footprint` sampled (every 20 ms) during the load.
  final int? peakFootprintBytes;
}

class Prediction {
  const Prediction({
    required this.ms,
    required this.footprintBytes,
    required this.mapWidth,
    required this.mapHeight,
    this.peakFootprintBytes,
    this.nonFinitePixels = 0,
  });

  /// The model call alone, timed natively (map writing excluded).
  final double ms;

  /// The app's `phys_footprint` right after the call.
  final int? footprintBytes;

  /// Highest `phys_footprint` sampled (every 20 ms) during the call: the
  /// transient peak jetsam counts, which [footprintBytes] misses.
  final int? peakFootprintBytes;
  final int mapWidth;
  final int mapHeight;

  /// Map pixels whose logits were NaN or infinite (FP16 overflow). Only
  /// counted when maps are written.
  final int nonFinitePixels;
}

/// The native side (`reefsight/coreml_bench` in `AppDelegate.swift`).
abstract interface class CoreMlBench {
  /// `MLModel.compileModel(at:)`, moved to [destPath] (`.mlmodelc`).
  Future<CompileResult> compile(String mlpackagePath, String destPath);

  Future<ComputePlanSummary> computePlan(String compiledPath, ComputeUnits units);

  Future<LoadResult> load(String compiledPath, ComputeUnits units);

  /// Runs the model on a PNG of exactly the model's input size. With
  /// [argmaxPath] and [confidencePath], also writes the class map (uint8 per
  /// pixel, row-major, at the logits' 1/4 resolution) and the top softmax
  /// probability (uint8, ×255).
  Future<Prediction> predict(
    int handle,
    String inputPath, {
    String? argmaxPath,
    String? confidencePath,
  });

  Future<void> unload(int handle);

  /// The app's `phys_footprint` now, or `null` where it can't be read.
  Future<int?> footprintBytes();

  /// The hardware model (`utsname.machine`, e.g. `iPhone14,7` for an iPhone 14).
  Future<String?> deviceModel();
}

class NativeCoreMlBench implements CoreMlBench {
  const NativeCoreMlBench();

  static const _channel = MethodChannel('reefsight/coreml_bench');

  static double _ms(Object? v) => (v as num).toDouble();

  @override
  Future<CompileResult> compile(String mlpackagePath, String destPath) async {
    final r = await _channel.invokeMapMethod<Object?, Object?>('compile', {
      'mlpackagePath': mlpackagePath,
      'destPath': destPath,
    });
    return CompileResult(compiledPath: r!['compiledPath'] as String, compileMs: _ms(r['compileMs']));
  }

  @override
  Future<ComputePlanSummary> computePlan(String compiledPath, ComputeUnits units) async =>
      ComputePlanSummary.fromChannel(await _channel.invokeMapMethod<Object?, Object?>('computePlan', {
        'compiledPath': compiledPath,
        'computeUnits': units.name,
      }));

  @override
  Future<LoadResult> load(String compiledPath, ComputeUnits units) async {
    final r = await _channel.invokeMapMethod<Object?, Object?>('load', {
      'compiledPath': compiledPath,
      'computeUnits': units.name,
    });
    return LoadResult(
      handle: r!['handle'] as int,
      loadMs: _ms(r['loadMs']),
      peakFootprintBytes: r['peakFootprintBytes'] as int?,
    );
  }

  @override
  Future<Prediction> predict(
    int handle,
    String inputPath, {
    String? argmaxPath,
    String? confidencePath,
  }) async {
    final r = await _channel.invokeMapMethod<Object?, Object?>('predict', {
      'handle': handle,
      'inputPath': inputPath,
      'argmaxPath': argmaxPath,
      'confidencePath': confidencePath,
    });
    return Prediction(
      ms: _ms(r!['ms']),
      footprintBytes: r['footprintBytes'] as int?,
      peakFootprintBytes: r['peakFootprintBytes'] as int?,
      mapWidth: r['mapWidth'] as int,
      mapHeight: r['mapHeight'] as int,
      nonFinitePixels: r['nonFinitePixels'] as int? ?? 0,
    );
  }

  @override
  Future<void> unload(int handle) => _channel.invokeMethod<void>('unload', {'handle': handle});

  @override
  Future<int?> footprintBytes() => _channel.invokeMethod<int>('footprint');

  @override
  Future<String?> deviceModel() => _channel.invokeMethod<String>('deviceModel');
}

class SampleMaps {
  const SampleMaps({
    required this.sample,
    required this.argmaxPath,
    required this.confidencePath,
    required this.width,
    required this.height,
  });

  final String sample;

  /// Relative to the results folder.
  final String argmaxPath;
  final String confidencePath;
  final int width;
  final int height;

  Map<String, Object> toJson() => {
    'sample': sample,
    'argmax': argmaxPath,
    'confidence': confidencePath,
    'width': width,
    'height': height,
  };
}

/// One model on one compute-unit setting.
class ArmResult {
  ArmResult({required this.model, required this.units, required this.windowsPerPhoto});

  final String model;
  final ComputeUnits units;
  final int windowsPerPhoto;

  /// `null` when the compiled model was reused from an earlier arm. Only the
  /// first load of a model is cold; later loads hit Core ML's device cache.
  double? compileMs;
  double? loadMs;
  ComputePlanSummary? plan;
  final latenciesMs = <double>[];
  int? footprintBeforeBytes;
  int? footprintAfterLoadBytes;

  /// The highest `phys_footprint` seen, including the 20 ms samples taken
  /// natively during load and each prediction.
  int? footprintPeakBytes;
  final maps = <SampleMaps>[];

  /// Map pixels with NaN or infinite logits; any at all invalidates the arm.
  int nonFinitePixels = 0;
  ThermalLevel? thermalStart;
  ThermalLevel? thermalEnd;
  bool stopped = false;
  String? error;

  LatencyStats? get stats => error == null && latenciesMs.isNotEmpty ? LatencyStats.of(latenciesMs) : null;

  /// Median window time × windows per photo.
  double? get perPhotoMedianMs => stats == null ? null : stats!.median * windowsPerPhoto;

  Map<String, Object?> toJson() => {
    'model': model,
    'compute_units': units.name,
    'windows_per_photo': windowsPerPhoto,
    'compile_ms': compileMs,
    'load_ms': loadMs,
    'cold_load': compileMs != null,
    'thermal_start': thermalStart?.name,
    'thermal_end': thermalEnd?.name,
    'non_finite_pixels': nonFinitePixels,
    'stopped': stopped,
    'compute_plan': plan?.toJson(),
    'latency_ms': stats?.toJson(),
    'latencies_ms': latenciesMs,
    'per_photo_median_ms': perPhotoMedianMs,
    'footprint_before_bytes': footprintBeforeBytes,
    'footprint_after_load_bytes': footprintAfterLoadBytes,
    'footprint_peak_bytes': footprintPeakBytes,
    'maps': [for (final m in maps) m.toJson()],
    'error': error,
  };
}

class SustainedSample {
  const SustainedSample({
    required this.tSeconds,
    required this.ms,
    required this.thermal,
    required this.footprintBytes,
    required this.batteryPercent,
  });

  final double tSeconds;
  final double ms;
  final ThermalLevel? thermal;
  final int? footprintBytes;
  final int? batteryPercent;

  Map<String, Object?> toJson() => {
    't_s': tSeconds,
    'ms': ms,
    'thermal': thermal?.name,
    'footprint_bytes': footprintBytes,
    'battery_percent': batteryPercent,
  };
}

/// The heat-and-battery run: one inference per interval, for a dive's length.
class SustainedResult {
  SustainedResult({
    required this.model,
    required this.units,
    required this.duration,
    required this.interval,
  });

  final String model;
  final ComputeUnits units;
  final Duration duration;
  final Duration interval;
  final samples = <SustainedSample>[];
  int? batteryStart;
  int? batteryEnd;
  bool batteryCharging = false;
  bool stoppedEarly = false;
  String? error;

  ThermalLevel? get peakThermal {
    final levels = samples.map((s) => s.thermal).whereType<ThermalLevel>();
    return levels.isEmpty ? null : levels.reduce((a, b) => a.index >= b.index ? a : b);
  }

  double? get firstSeriousSeconds {
    for (final s in samples) {
      if (s.thermal != null && s.thermal!.index >= ThermalLevel.serious.index) return s.tSeconds;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'model': model,
    'compute_units': units.name,
    'duration_s': duration.inMilliseconds / 1000,
    'interval_s': interval.inMilliseconds / 1000,
    'n': samples.length,
    'latency_ms': samples.isEmpty ? null : LatencyStats.of([for (final s in samples) s.ms]).toJson(),
    'peak_thermal': peakThermal?.name,
    'first_serious_s': firstSeriousSeconds,
    'battery_start': batteryStart,
    'battery_end': batteryEnd,
    'battery_charging': batteryCharging,
    'stopped_early': stoppedEarly,
    'error': error,
    'samples': [for (final s in samples) s.toJson()],
  };
}

/// Drives [CoreMlBench] through the test matrix and the sustained run, and
/// writes everything to [outDir] (`log.txt`, `maps/`, `bench_results.json`).
class BenchmarkRunner {
  BenchmarkRunner({
    required this.bench,
    required this.package,
    required this.outDir,
    required this.thermal,
    required this.battery,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.onLog,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  final CoreMlBench bench;
  final BenchPackage package;
  final Directory outDir;
  final ThermalInfo thermal;
  final BatteryInfo battery;
  final void Function(String)? onLog;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final _compiled = <String, String>{};

  void _log(String message) {
    outDir.createSync(recursive: true);
    File(p.join(outDir.path, 'log.txt'))
        .writeAsStringSync('${_now().toIso8601String()}  $message\n', mode: FileMode.append);
    onLog?.call(message);
  }

  /// Compiles [model] once per runner; later arms reuse the `.mlmodelc`.
  Future<(String, double?)> _compile(BenchModel model) async {
    final cached = _compiled[model.name];
    if (cached != null) return (cached, null);
    final dest = p.join(package.root.path, 'compiled', '${model.name}.mlmodelc');
    _log('${model.name}: compiling...');
    final r = await bench.compile(package.resolve(model.path), dest);
    _compiled[model.name] = r.compiledPath;
    _log('${model.name}: compiled in ${(r.compileMs / 1000).toStringAsFixed(1)} s');
    return (r.compiledPath, r.compileMs);
  }

  /// Times [model] on [units]. Warm-up covers every sample at least once and
  /// writes its class maps; the [iterations] timed runs write none. A failure
  /// is recorded on the arm rather than thrown, so one arm can't sink the matrix.
  Future<ArmResult> runArm(
    BenchModel model,
    ComputeUnits units, {
    int warmup = 3,
    int iterations = 30,
    bool Function()? shouldStop,
    bool readPlan = true,
  }) async {
    final arm = ArmResult(model: model.name, units: units, windowsPerPhoto: model.windowsPerPhoto);
    final tag = '${model.name}/${units.name}';
    final samples = package.manifest.samples;
    int? handle;
    void track(int? bytes) {
      if (bytes != null && bytes > (arm.footprintPeakBytes ?? 0)) arm.footprintPeakBytes = bytes;
    }

    bool stop() => arm.stopped = arm.stopped || (shouldStop?.call() ?? false);

    try {
      arm.thermalStart = await thermal.current();
      final (compiled, compileMs) = await _compile(model);
      arm.compileMs = compileMs;
      // The compute plan loads the model a second time; skippable to spare memory.
      if (readPlan) {
        _log('$tag: reading compute plan...');
        try {
          arm.plan = await bench.computePlan(compiled, units);
        } catch (error) {
          _log('$tag: no compute plan ($error)');
          arm.plan = const ComputePlanSummary(available: false);
        }
      }
      arm.footprintBeforeBytes = await bench.footprintBytes();
      track(arm.footprintBeforeBytes);
      // Each step is logged before it starts, so after a crash the last line of
      // log.txt names the step that died.
      _log('$tag: loading...');
      final loaded = await bench.load(compiled, units);
      handle = loaded.handle;
      arm.loadMs = loaded.loadMs;
      track(loaded.peakFootprintBytes);
      arm.footprintAfterLoadBytes = await bench.footprintBytes();
      track(arm.footprintAfterLoadBytes);

      final warm = math.max(warmup, samples.length);
      _log('$tag: loaded in ${(loaded.loadMs / 1000).toStringAsFixed(1)} s; $warm warm-up runs...');
      for (var i = 0; i < warm && !stop(); i++) {
        final sample = samples[i % samples.length];
        final input = package.resolve(sample.inputFor(model.inputSize));
        if (i < samples.length) {
          final rel = p.join('maps', model.name, units.name);
          await Directory(p.join(outDir.path, rel)).create(recursive: true);
          final argmax = p.join(rel, '${sample.id}_argmax.bin');
          final conf = p.join(rel, '${sample.id}_conf.bin');
          final r = await bench.predict(handle, input,
              argmaxPath: p.join(outDir.path, argmax), confidencePath: p.join(outDir.path, conf));
          track(r.footprintBytes);
          track(r.peakFootprintBytes);
          arm.nonFinitePixels += r.nonFinitePixels;
          arm.maps.add(SampleMaps(
            sample: sample.id,
            argmaxPath: p.posix.joinAll(p.split(argmax)),
            confidencePath: p.posix.joinAll(p.split(conf)),
            width: r.mapWidth,
            height: r.mapHeight,
          ));
        } else {
          final r = await bench.predict(handle, input);
          track(r.footprintBytes);
          track(r.peakFootprintBytes);
        }
      }
      _log('$tag: $iterations timed runs...');
      for (var i = 0; i < iterations && !stop(); i++) {
        final sample = samples[(warm + i) % samples.length];
        final r = await bench.predict(handle, package.resolve(sample.inputFor(model.inputSize)));
        arm.latenciesMs.add(r.ms);
        track(r.footprintBytes);
        track(r.peakFootprintBytes);
      }
      arm.thermalEnd = await thermal.current();
      final s = arm.stats;
      _log('${model.name}/${units.name}: ${s == null ? 'no timed runs' : 'median '
          '${s.median.toStringAsFixed(0)} ms, p90 ${s.p90.toStringAsFixed(0)} ms per window, '
          '~${(arm.perPhotoMedianMs! / 1000).toStringAsFixed(1)} s per photo'}, heat '
          '${arm.thermalStart?.name ?? '-'} -> ${arm.thermalEnd?.name ?? '-'}'
          '${arm.nonFinitePixels > 0 ? ', ${arm.nonFinitePixels} NaN/inf map pixels: INVALID' : ''}'
          '${arm.stopped ? ' (stopped)' : ''}');
    } catch (error) {
      arm.error = '$error';
      _log('${model.name}/${units.name}: FAILED: $error');
    } finally {
      if (handle != null) {
        try {
          await bench.unload(handle);
        } catch (error) {
          _log('${model.name}/${units.name}: unload failed: $error');
        }
      }
    }
    return arm;
  }

  /// The quick test, the least strain on the phone: the lightest model
  /// ([BenchManifest.lightestFirst]) on CPU + Neural Engine, no compute plan,
  /// 10 timed runs. It answers whether the phone can run the model at all,
  /// and how fast at its cheapest, before the full matrix is attempted.
  Future<ArmResult> runQuick({bool Function()? shouldStop}) => runArm(
    package.manifest.lightestFirst.first,
    ComputeUnits.cpuAndNeuralEngine,
    warmup: 3,
    iterations: 10,
    shouldStop: shouldStop,
    readPlan: false,
  );

  /// Every model on every one of [units], lightest model first, so a crash
  /// on a heavy model still leaves results for the light ones. Before each
  /// arm the phone is let cool to [coolTo] (up to [maxCoolDown]), so later
  /// arms aren't timed heat-soaked; [onArm] fires after each one, so the
  /// caller can save results as they come in.
  Future<List<ArmResult>> runMatrix({
    List<ComputeUnits> units = const [ComputeUnits.cpuAndNeuralEngine, ComputeUnits.all, ComputeUnits.cpuAndGpu],
    int warmup = 3,
    int iterations = 30,
    bool Function()? shouldStop,
    ThermalLevel coolTo = ThermalLevel.fair,
    Duration maxCoolDown = const Duration(minutes: 10),
    Duration coolPoll = const Duration(seconds: 15),
    Future<void> Function(ArmResult arm)? onArm,
  }) async {
    final arms = <ArmResult>[];
    for (final model in package.manifest.lightestFirst) {
      for (final u in units) {
        if (shouldStop?.call() ?? false) return arms;
        await _coolDown(coolTo, maxCoolDown, coolPoll, shouldStop);
        final arm = await runArm(model, u, warmup: warmup, iterations: iterations, shouldStop: shouldStop);
        arms.add(arm);
        await onArm?.call(arm);
      }
    }
    return arms;
  }

  Future<void> _coolDown(ThermalLevel to, Duration max, Duration poll, bool Function()? shouldStop) async {
    final start = _now();
    var level = await thermal.current();
    if (level == null || level.index <= to.index) return;
    _log('Cooling down from ${level.name} before the next arm');
    while (level != null && level.index > to.index && _now().difference(start) < max) {
      if (shouldStop?.call() ?? false) return;
      await _delay(poll);
      level = await thermal.current();
    }
    _log('Cool-down ended at ${level?.name ?? '-'} after ${_now().difference(start).inSeconds} s');
  }

  /// One inference every [interval] for [duration] (default: 1.5 s for 20
  /// min, a dive's length), recording latency, heat, memory and battery.
  Future<SustainedResult> runSustained(
    BenchModel model,
    ComputeUnits units, {
    Duration duration = const Duration(minutes: 20),
    Duration interval = const Duration(milliseconds: 1500),
    bool Function()? shouldStop,
    void Function(SustainedSample)? onSample,
  }) async {
    final result = SustainedResult(model: model.name, units: units, duration: duration, interval: interval);
    final samples = package.manifest.samples;
    int? handle;
    _log('Sustained ${model.name}/${units.name}: every ${interval.inMilliseconds} ms '
        'for ${duration.inMinutes} min');
    try {
      final b = await battery.read();
      result.batteryStart = b?.percent;
      result.batteryCharging = b?.charging ?? false;
      final (compiled, _) = await _compile(model);
      handle = (await bench.load(compiled, units)).handle;
      // Untimed: the first call after a load pays for lazy device specialization.
      await bench.predict(handle, package.resolve(samples.first.inputFor(model.inputSize)));
      final checkpoint = File(p.join(outDir.path, 'sustained_partial.json'));
      await outDir.create(recursive: true);
      final start = _now();
      for (var i = 0;; i++) {
        if (shouldStop?.call() ?? false) {
          result.stoppedEarly = true;
          break;
        }
        final t0 = _now();
        if (t0.difference(start) >= duration) break;
        final sample = samples[i % samples.length];
        final r = await bench.predict(handle, package.resolve(sample.inputFor(model.inputSize)));
        final s = SustainedSample(
          tSeconds: t0.difference(start).inMilliseconds / 1000,
          ms: r.ms,
          thermal: await thermal.current(),
          footprintBytes: r.footprintBytes,
          batteryPercent: (await battery.read())?.percent,
        );
        result.samples.add(s);
        onSample?.call(s);
        // A 20 min run killed by the OS (heat, memory) still leaves its data.
        if (result.samples.length % 20 == 0) {
          await checkpoint.writeAsString(jsonEncode(result.toJson()));
        }
        final wait = interval - _now().difference(t0);
        if (wait > Duration.zero) await _delay(wait);
      }
    } catch (error) {
      result.error = '$error';
      _log('Sustained ${model.name}/${units.name}: FAILED: $error');
    } finally {
      if (handle != null) {
        try {
          await bench.unload(handle);
        } catch (error) {
          _log('Sustained: unload failed: $error');
        }
      }
      try {
        result.batteryEnd = (await battery.read())?.percent;
      } catch (_) {}
    }
    _log('Sustained ${model.name}/${units.name}: ${result.samples.length} runs, peak heat '
        '${result.peakThermal?.name ?? '-'}, first serious at ${result.firstSeriousSeconds ?? '-'} s, '
        'battery ${result.batteryStart ?? '-'} -> ${result.batteryEnd ?? '-'} %'
        '${result.stoppedEarly ? ' (stopped early)' : ''}');
    return result;
  }

  /// Writes `bench_results.json`, the file the notebook reads back. Safe to
  /// call after every arm: it rewrites the whole file each time.
  Future<File> writeReport({
    required List<ArmResult> arms,
    List<SustainedResult> sustained = const [],
    required String device,
  }) async {
    await outDir.create(recursive: true);
    final m = package.manifest;
    final json = {
      'format': kBenchResultsFormat,
      'version': kBenchVersion,
      'created_at': _now().toUtc().toIso8601String(),
      'bench_run_id': m.runId,
      'hf_model': m.hfModel,
      'hf_revision': m.hfRevision,
      'device': device,
      'arms': [for (final a in arms) a.toJson()],
      'sustained': [for (final s in sustained) s.toJson()],
    };
    final file = File(p.join(outDir.path, 'bench_results.json'));
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(json));
    _log('Wrote ${file.path}');
    return file;
  }
}
