import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/services/coreml_benchmark.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_info.dart';

// Issue #11: the Core ML speed test for the CoralscapesV2 SegFormer. The
// notebook (29_coralscapes_coreml_export) packs the converted models and
// sample windows; the phone times them and writes the class maps back for
// the notebook to compare with PyTorch. The native side is faked here.

Map<String, Object?> manifestJson({
  String format = 'reefsight-coreml-bench',
  int version = 1,
  List<Map<String, Object?>>? models,
  List<Map<String, Object?>>? samples,
}) => {
  'format': format,
  'version': version,
  'run_id': '20261114_120000',
  'hf_model': 'EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024',
  'hf_revision': 'c61183ec41b40a660491ea90babf54ff40b673dd',
  'num_classes': 40,
  'models':
      models ??
      [
        {
          'name': 'cs_1024',
          'path': 'models/cs_1024.mlpackage',
          'input_size': 1024,
          'weights': 'fp16',
          'windows_per_photo': 2,
        },
        {
          'name': 'cs_512',
          'path': 'models/cs_512.mlpackage',
          'input_size': 512,
          'weights': 'fp16',
          'windows_per_photo': 2,
        },
      ],
  'samples':
      samples ??
      [
        {
          'id': 's01',
          'inputs': {'1024': 'samples/s01_1024.png', '512': 'samples/s01_512.png'},
        },
        {
          'id': 's02',
          'inputs': {'1024': 'samples/s02_1024.png', '512': 'samples/s02_512.png'},
        },
      ],
};

class FakeBench implements CoreMlBench {
  FakeBench({this.latencies = const [1000], this.failPredictAfter, this.nonFinite = 0, this.peakExtra = 0});

  /// Cycled through, one per prediction.
  final List<double> latencies;
  final int? failPredictAfter;

  /// NaN/inf pixels reported by each prediction that writes maps.
  final int nonFinite;

  /// How far each prediction's sampled peak sits above its post-call reading.
  final int peakExtra;

  final compiled = <String>[];
  final loaded = <(String, ComputeUnits)>[];
  final unloaded = <int>[];
  final predictions = <(int, String, String?, String?)>[];
  int _handle = 0;
  int footprint = 100;

  @override
  Future<CompileResult> compile(String mlpackagePath, String destPath) async {
    compiled.add(mlpackagePath);
    Directory(destPath).createSync(recursive: true);
    return CompileResult(compiledPath: destPath, compileMs: 5000);
  }

  @override
  Future<ComputePlanSummary> computePlan(String compiledPath, ComputeUnits units) async =>
      const ComputePlanSummary(available: true, neuralEngine: 90, gpu: 5, cpu: 5, other: 0);

  @override
  Future<LoadResult> load(String compiledPath, ComputeUnits units) async {
    loaded.add((compiledPath, units));
    return LoadResult(handle: ++_handle, loadMs: 800);
  }

  @override
  Future<Prediction> predict(
    int handle,
    String inputPath, {
    String? argmaxPath,
    String? confidencePath,
  }) async {
    if (failPredictAfter != null && predictions.length >= failPredictAfter!) {
      throw StateError('Neural Engine went away');
    }
    final ms = latencies[predictions.length % latencies.length];
    predictions.add((handle, inputPath, argmaxPath, confidencePath));
    footprint += 10;
    return Prediction(
      ms: ms,
      footprintBytes: footprint,
      peakFootprintBytes: peakExtra == 0 ? null : footprint + peakExtra,
      mapWidth: 256,
      mapHeight: 256,
      nonFinitePixels: argmaxPath == null ? 0 : nonFinite,
    );
  }

  @override
  Future<void> unload(int handle) async => unloaded.add(handle);

  @override
  Future<int?> footprintBytes() async => footprint;

  @override
  Future<String?> deviceModel() async => 'iPhone14,7';
}

class FakeThermal implements ThermalInfo {
  FakeThermal(this.levels);

  final List<ThermalLevel> levels;
  int reads = 0;

  @override
  Future<ThermalLevel?> current() async => levels[(reads++).clamp(0, levels.length - 1)];

  @override
  Stream<ThermalLevel> get changes => const Stream.empty();
}

class FakeBattery implements BatteryInfo {
  FakeBattery(this.percents);

  final List<int> percents;
  int reads = 0;

  @override
  Future<BatteryReading?> read() async =>
      BatteryReading(percent: percents[(reads++).clamp(0, percents.length - 1)], charging: false);

  @override
  Stream<void> get changes => const Stream.empty();
}

/// A clock the runner advances only through [delay] and the fake's latency.
class FakeClock {
  DateTime t = DateTime.utc(2026, 11, 14, 12);
  DateTime now() => t;
  Future<void> delay(Duration d) async => t = t.add(d);
}

void main() {
  group('BenchManifest.fromJson', () {
    test('reads models and samples', () {
      final m = BenchManifest.fromJson(manifestJson());
      expect(m.runId, '20261114_120000');
      expect(m.numClasses, 40);
      expect(m.models.map((x) => x.name), ['cs_1024', 'cs_512']);
      expect(m.models.first.inputSize, 1024);
      expect(m.models.first.windowsPerPhoto, 2);
      expect(m.samples.map((s) => s.id), ['s01', 's02']);
      expect(m.samples.first.inputFor(512), 'samples/s01_512.png');
    });

    test('rejects another format or version', () {
      expect(() => BenchManifest.fromJson(manifestJson(format: 'reefsight-analysis')),
          throwsFormatException);
      expect(() => BenchManifest.fromJson(manifestJson(version: 2)), throwsFormatException);
    });

    test('rejects a sample with no input at a model size', () {
      expect(
        () => BenchManifest.fromJson(manifestJson(samples: [
          {
            'id': 's01',
            'inputs': {'1024': 'samples/s01_1024.png'},
          },
        ])),
        throwsFormatException,
      );
    });

    test('rejects a run_id that is not a plain name (it names folders)', () {
      for (final bad in ['../..', '/abs', 'a/b', '', null]) {
        final json = manifestJson()..['run_id'] = bad;
        expect(() => BenchManifest.fromJson(json), throwsFormatException, reason: '$bad');
      }
    });

    test('rejects paths that leave the package', () {
      expect(
        () => BenchManifest.fromJson(manifestJson(models: [
          {
            'name': 'cs_1024',
            'path': '../cs_1024.mlpackage',
            'input_size': 1024,
            'weights': 'fp16',
            'windows_per_photo': 2,
          },
        ])),
        throwsFormatException,
      );
    });
  });

  group('LatencyStats', () {
    test('median, p90 (nearest rank), mean, min, max', () {
      final s = LatencyStats.of([5, 1, 4, 2, 3, 10, 6, 7, 8, 9]);
      expect(s.n, 10);
      expect(s.min, 1);
      expect(s.max, 10);
      expect(s.median, 5.5);
      expect(s.p90, 9);
      expect(s.mean, 5.5);
    });

    test('odd count median is the middle value', () {
      expect(LatencyStats.of([3, 1, 2]).median, 2);
    });

    test('empty input throws', () {
      expect(() => LatencyStats.of([]), throwsArgumentError);
    });
  });

  test('ComputePlanSummary.fromChannel and the Neural Engine share', () {
    final plan = ComputePlanSummary.fromChannel({
      'available': true,
      'neuralEngine': 180,
      'gpu': 10,
      'cpu': 10,
      'other': 0,
    });
    expect(plan.total, 200);
    expect(plan.neuralEngineShare, closeTo(0.9, 1e-9));
    expect(ComputePlanSummary.fromChannel({'available': false}).available, isFalse);
    expect(ComputePlanSummary.fromChannel(null).available, isFalse);
  });

  group('extractBenchPackage', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bench_pkg_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String zipOf(Map<String, String> entries) {
      final path = p.join(tmp.path, 'bench.zip');
      final encoder = ZipFileEncoder()..create(path);
      for (final e in entries.entries) {
        encoder.addArchiveFile(ArchiveFile.string(e.key, e.value));
      }
      encoder.closeSync();
      return path;
    }

    test('unzips into <packages>/<run_id>/ and returns the folder that holds the manifest', () async {
      final zip = zipOf({
        'coralscapes_bench_X/bench_manifest.json': jsonEncode(manifestJson()),
        'coralscapes_bench_X/models/cs_1024.mlpackage/Manifest.json': '{}',
      });
      final out = Directory(p.join(tmp.path, 'out'));
      final pkg = await extractBenchPackage(zip, out);
      expect(pkg.root.path, p.join(out.path, '20261114_120000', 'coralscapes_bench_X'));
      expect(pkg.manifest.models, hasLength(2));
      expect(File(p.join(pkg.root.path, 'models', 'cs_1024.mlpackage', 'Manifest.json')).existsSync(),
          isTrue);
      // No temporary folder is left behind.
      expect(out.listSync().map((e) => p.basename(e.path)), ['20261114_120000']);
    });

    test('a second unzip of the same run replaces the first', () async {
      final out = Directory(p.join(tmp.path, 'out'));
      await extractBenchPackage(
          zipOf({'pkg/bench_manifest.json': jsonEncode(manifestJson()), 'pkg/old.txt': 'old'}), out);
      final pkg = await extractBenchPackage(
          zipOf({'pkg/bench_manifest.json': jsonEncode(manifestJson()), 'pkg/new.txt': 'new'}), out);
      expect(File(p.join(pkg.root.path, 'new.txt')).existsSync(), isTrue);
      expect(File(p.join(pkg.root.path, 'old.txt')).existsSync(), isFalse);
    });

    test('a bad manifest writes nothing', () async {
      final out = Directory(p.join(tmp.path, 'out'));
      final zip = zipOf({'pkg/bench_manifest.json': jsonEncode(manifestJson(version: 9)), 'pkg/a.txt': 'a'});
      await expectLater(extractBenchPackage(zip, out), throwsFormatException);
      expect(out.existsSync(), isFalse);
    });

    test('refuses an entry that escapes the folder, before writing anything', () async {
      final zip = zipOf({
        'pkg/bench_manifest.json': jsonEncode(manifestJson()),
        '../evil.txt': 'x',
      });
      await expectLater(
          extractBenchPackage(zip, Directory(p.join(tmp.path, 'out'))), throwsFormatException);
      expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'out')).existsSync(), isFalse);
    });

    test('refuses a zip with no manifest', () async {
      final zip = zipOf({'pkg/readme.txt': 'hello'});
      await expectLater(
          extractBenchPackage(zip, Directory(p.join(tmp.path, 'out'))), throwsFormatException);
    });
  });

  group('BenchmarkRunner.runArm', () {
    late Directory tmp;
    late BenchManifest manifest;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bench_run_');
      manifest = BenchManifest.fromJson(manifestJson());
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    BenchmarkRunner runner(FakeBench bench, [FakeClock? clock]) {
      clock ??= FakeClock();
      return BenchmarkRunner(
        bench: bench,
        package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
        outDir: Directory(p.join(tmp.path, 'out')),
        thermal: FakeThermal([ThermalLevel.nominal]),
        battery: FakeBattery([90]),
        now: clock.now,
        delay: clock.delay,
      );
    }

    test('warms up over every sample writing maps, then times the iterations', () async {
      final bench = FakeBench(latencies: [1200, 1000, 1100, 900]);
      final arm = await runner(bench)
          .runArm(manifest.models.first, ComputeUnits.cpuAndNeuralEngine, warmup: 1, iterations: 4);

      // Warm-up is stretched to cover both samples, so each one's maps get written.
      final warm = bench.predictions.take(2).toList();
      expect(warm.map((x) => p.basename(x.$2)), ['s01_1024.png', 's02_1024.png']);
      expect(warm.every((x) => x.$3 != null && x.$4 != null), isTrue);
      expect(warm.first.$3, endsWith(p.join('maps', 'cs_1024', 'cpuAndNeuralEngine', 's01_argmax.bin')));
      // Timed runs write no maps, and cycle through the samples.
      final timed = bench.predictions.skip(2).toList();
      expect(timed, hasLength(4));
      expect(timed.every((x) => x.$3 == null && x.$4 == null), isTrue);

      expect(arm.error, isNull);
      expect(arm.compileMs, 5000);
      expect(arm.loadMs, 800);
      expect(arm.latenciesMs, [1100, 900, 1200, 1000]);
      expect(arm.stats!.median, 1050);
      expect(arm.perPhotoMedianMs, 2100);
      expect(arm.plan!.neuralEngine, 90);
      expect(arm.footprintPeakBytes, 160);
      expect(arm.maps.map((m) => m.sample), ['s01', 's02']);
      expect(bench.unloaded, [1]);
    });

    test('compiles each model once across compute units', () async {
      final bench = FakeBench();
      final r = runner(bench);
      final a = await r.runArm(manifest.models.first, ComputeUnits.all, warmup: 0, iterations: 1);
      final b = await r.runArm(manifest.models.first, ComputeUnits.cpuAndGpu, warmup: 0, iterations: 1);
      expect(bench.compiled, hasLength(1));
      expect(a.compileMs, 5000);
      expect(b.compileMs, isNull);
      expect(bench.loaded.map((x) => x.$2), [ComputeUnits.all, ComputeUnits.cpuAndGpu]);
    });

    test('a failing arm is recorded, unloaded, and does not throw', () async {
      final bench = FakeBench(failPredictAfter: 3);
      final arm = await runner(bench)
          .runArm(manifest.models.first, ComputeUnits.all, warmup: 0, iterations: 10);
      expect(arm.error, contains('Neural Engine went away'));
      expect(arm.stats, isNull);
      expect(bench.unloaded, [1]);
    });

    test('runMatrix runs every model on every requested compute unit, reporting each', () async {
      final bench = FakeBench();
      final reported = <String>[];
      final arms = await runner(bench).runMatrix(
        units: [ComputeUnits.cpuAndNeuralEngine, ComputeUnits.all],
        warmup: 0,
        iterations: 2,
        onArm: (a) async => reported.add('${a.model}/${a.units.name}'),
      );
      expect(arms.map((a) => '${a.model}/${a.units.name}'), [
        'cs_1024/cpuAndNeuralEngine',
        'cs_1024/all',
        'cs_512/cpuAndNeuralEngine',
        'cs_512/all',
      ]);
      expect(reported, arms.map((a) => '${a.model}/${a.units.name}'));
    });

    test('the sampled peak during a call counts, and heat is recorded per arm', () async {
      final bench = FakeBench(peakExtra: 1000);
      final arm = await runner(bench).runArm(manifest.models.first, ComputeUnits.all, warmup: 0, iterations: 1);
      expect(arm.footprintPeakBytes, 130 + 1000);
      expect(arm.thermalStart, ThermalLevel.nominal);
      expect(arm.thermalEnd, ThermalLevel.nominal);
    });

    test('NaN or infinite logits in the maps are counted and reported', () async {
      final bench = FakeBench(nonFinite: 7);
      final arm = await runner(bench).runArm(manifest.models.first, ComputeUnits.all, warmup: 0, iterations: 1);
      expect(arm.nonFinitePixels, 14); // 7 per sample map, 2 samples
      expect(arm.toJson()['non_finite_pixels'], 14);
    });

    test('stop is honoured inside an arm', () async {
      final bench = FakeBench();
      var calls = 0;
      final arm = await runner(bench).runArm(manifest.models.first, ComputeUnits.cpuOnly,
          warmup: 0, iterations: 30, shouldStop: () => ++calls > 5);
      expect(arm.stopped, isTrue);
      expect(bench.predictions.length, lessThan(10));
    });

    test('the matrix waits for the phone to cool before an arm', () async {
      final clock = FakeClock();
      final thermal = FakeThermal([ThermalLevel.serious, ThermalLevel.serious, ThermalLevel.fair]);
      final r = BenchmarkRunner(
        bench: FakeBench(),
        package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
        outDir: Directory(p.join(tmp.path, 'out')),
        thermal: thermal,
        battery: FakeBattery([90]),
        now: clock.now,
        delay: clock.delay,
      );
      final start = clock.t;
      await r.runMatrix(units: [ComputeUnits.all], warmup: 0, iterations: 1);
      // serious, 15 s, serious, 15 s, fair: then the first arm starts.
      expect(clock.t.difference(start), const Duration(seconds: 30));
    });
  });

  group('BenchmarkRunner.runSustained', () {
    late Directory tmp;
    late BenchManifest manifest;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bench_sus_');
      manifest = BenchManifest.fromJson(manifestJson());
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('one inference per interval for the duration, with heat and battery', () async {
      final clock = FakeClock();
      final bench = FakeBench(latencies: [500]);
      final thermal = FakeThermal([
        ThermalLevel.nominal,
        ThermalLevel.fair,
        ThermalLevel.fair,
        ThermalLevel.serious,
      ]);
      final r = BenchmarkRunner(
        bench: bench,
        package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
        outDir: Directory(p.join(tmp.path, 'out')),
        thermal: thermal,
        battery: FakeBattery([88, 87, 86, 85, 84, 83, 82]),
        now: clock.now,
        delay: clock.delay,
      );
      final s = await r.runSustained(
        manifest.models.last,
        ComputeUnits.cpuAndNeuralEngine,
        duration: const Duration(seconds: 6),
        interval: const Duration(milliseconds: 1500),
      );
      // The fake predictor takes no wall time, so the clock moves only by the waits.
      expect(s.samples, hasLength(4));
      expect(s.samples.map((x) => x.tSeconds), [0, 1.5, 3, 4.5]);
      expect(s.samples.map((x) => x.thermal), [
        ThermalLevel.nominal,
        ThermalLevel.fair,
        ThermalLevel.fair,
        ThermalLevel.serious,
      ]);
      expect(s.peakThermal, ThermalLevel.serious);
      expect(s.firstSeriousSeconds, 4.5);
      expect(s.batteryStart, 88);
      expect(s.batteryEnd, isNotNull);
      expect(s.stoppedEarly, isFalse);
      expect(bench.unloaded, hasLength(1));
      // One untimed warm-up call before the clock starts.
      expect(bench.predictions, hasLength(5));
    });

    test('saves a checkpoint every 20 runs', () async {
      final clock = FakeClock();
      final out = Directory(p.join(tmp.path, 'out'));
      final r = BenchmarkRunner(
        bench: FakeBench(),
        package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
        outDir: out,
        thermal: FakeThermal([ThermalLevel.nominal]),
        battery: FakeBattery([60]),
        now: clock.now,
        delay: clock.delay,
      );
      await r.runSustained(manifest.models.first, ComputeUnits.all,
          duration: const Duration(seconds: 45), interval: const Duration(seconds: 1));
      final partial = jsonDecode(File(p.join(out.path, 'sustained_partial.json')).readAsStringSync()) as Map;
      expect(partial['n'], 40);
    });

    test('stops early when asked', () async {
      final clock = FakeClock();
      final bench = FakeBench();
      var n = 0;
      final r = BenchmarkRunner(
        bench: bench,
        package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
        outDir: Directory(p.join(tmp.path, 'out')),
        thermal: FakeThermal([ThermalLevel.nominal]),
        battery: FakeBattery([50]),
        now: clock.now,
        delay: clock.delay,
      );
      final s = await r.runSustained(
        manifest.models.first,
        ComputeUnits.all,
        duration: const Duration(minutes: 20),
        interval: const Duration(seconds: 1),
        shouldStop: () => ++n > 3,
      );
      expect(s.samples, hasLength(3));
      expect(s.stoppedEarly, isTrue);
    });
  });

  test('BenchReport writes bench_results.json with every arm', () async {
    final tmp = Directory.systemTemp.createTempSync('bench_rep_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final manifest = BenchManifest.fromJson(manifestJson());
    final clock = FakeClock();
    final r = BenchmarkRunner(
      bench: FakeBench(),
      package: BenchPackage(root: Directory(p.join(tmp.path, 'pkg')), manifest: manifest),
      outDir: Directory(p.join(tmp.path, 'out')),
      thermal: FakeThermal([ThermalLevel.nominal]),
      battery: FakeBattery([70]),
      now: clock.now,
      delay: clock.delay,
    );
    final arm = await r.runArm(manifest.models.first, ComputeUnits.all, warmup: 0, iterations: 2);
    final file = await r.writeReport(arms: [arm], device: 'iPhone 14 / iOS 26.1');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(json['format'], 'reefsight-coreml-bench-results');
    expect(json['version'], 1);
    expect(json['bench_run_id'], '20261114_120000');
    expect(json['device'], 'iPhone 14 / iOS 26.1');
    final arms = json['arms'] as List;
    expect(arms.single['model'], 'cs_1024');
    expect(arms.single['compute_units'], 'all');
    expect(arms.single['latency_ms']['median'], 1000);
    expect(arms.single['per_photo_median_ms'], 2000);
    expect(json['sustained'], isEmpty);
  });
}
