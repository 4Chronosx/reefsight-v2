import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reefsight_mobile/screens/coreml_benchmark_screen.dart';
import 'package:reefsight_mobile/services/coreml_benchmark.dart';
import 'package:reefsight_mobile/services/device_checks.dart';
import 'package:reefsight_mobile/services/device_info.dart';
import 'package:reefsight_mobile/services/screen_awake.dart';

// Issue #11: the dev screen that loads a benchmark package, runs the Core ML
// test matrix, and shares the results back for the notebook. The native
// bench, the picker and the share sheet are faked.

class _Bench implements CoreMlBench {
  @override
  Future<CompileResult> compile(String mlpackagePath, String destPath) async =>
      CompileResult(compiledPath: destPath, compileMs: 4000);

  @override
  Future<ComputePlanSummary> computePlan(String compiledPath, ComputeUnits units) async =>
      const ComputePlanSummary(available: true, neuralEngine: 9, gpu: 1);

  @override
  Future<LoadResult> load(String compiledPath, ComputeUnits units) async =>
      const LoadResult(handle: 1, loadMs: 700);

  @override
  Future<Prediction> predict(int handle, String inputPath, {String? argmaxPath, String? confidencePath}) async =>
      const Prediction(ms: 1500, footprintBytes: 900000000, mapWidth: 256, mapHeight: 256);

  @override
  Future<void> unload(int handle) async {}

  @override
  Future<int?> footprintBytes() async => 500000000;

  @override
  Future<String?> deviceModel() async => 'iPhone14,7';
}

class _Thermal implements ThermalInfo {
  @override
  Future<ThermalLevel?> current() async => ThermalLevel.nominal;

  @override
  Stream<ThermalLevel> get changes => const Stream.empty();
}

class _Battery implements BatteryInfo {
  @override
  Future<BatteryReading?> read() async => const BatteryReading(percent: 80, charging: false);

  @override
  Stream<void> get changes => const Stream.empty();
}

class _Awake implements ScreenAwake {
  int enabled = 0;
  int disabled = 0;

  @override
  Future<void> enable() async => enabled++;

  @override
  Future<void> disable() async => disabled++;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bench_screen_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String benchZip({bool valid = true}) {
    final path = p.join(tmp.path, 'coralscapes_bench_X.zip');
    final encoder = ZipFileEncoder()..create(path);
    encoder.addArchiveFile(ArchiveFile.string(
      'coralscapes_bench_X/bench_manifest.json',
      jsonEncode({
        'format': valid ? 'reefsight-coreml-bench' : 'something-else',
        'version': 1,
        'run_id': '20261114_120000',
        'hf_model': 'EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024',
        'hf_revision': 'c61183ec',
        'num_classes': 40,
        'models': [
          {'name': 'cs_1024', 'path': 'models/cs_1024.mlpackage', 'input_size': 1024, 'weights': 'fp16', 'windows_per_photo': 2},
          {'name': 'cs_512', 'path': 'models/cs_512.mlpackage', 'input_size': 512, 'weights': 'fp16', 'windows_per_photo': 2},
        ],
        'samples': [
          {
            'id': 's01',
            'inputs': {'1024': 'samples/s01_1024.png', '512': 'samples/s01_512.png'},
          },
        ],
      }),
    ));
    encoder.closeSync();
    return path;
  }

  Future<List<Directory>> pump(WidgetTester tester, {required String zip, _Awake? awake}) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shared = <Directory>[];
    await tester.pumpWidget(MaterialApp(
      home: CoreMlBenchmarkScreen(
        bench: _Bench(),
        thermal: _Thermal(),
        battery: _Battery(),
        screenAwake: awake ?? _Awake(),
        pickPackage: () async => zip,
        workDir: () async => Directory(p.join(tmp.path, 'docs')),
        shareResults: (dir) async => shared.add(dir),
        deviceLabel: (bench) async => '${await bench.deviceModel()} test device',
      ),
    ));
    return shared;
  }

  /// Unzipping and the runner use real file I/O, outside the fake clock, so
  /// let real time pass until the screen stops showing a busy label ('…').
  Future<void> tapAndWait(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (i >= 2 && find.textContaining('…').evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('loads a package, runs the matrix, and shares the results', (tester) async {
    final awake = _Awake();
    final shared = await pump(tester, zip: benchZip(), awake: awake);
    expect(find.byKey(const Key('bench-run-matrix')), findsNothing);

    await tapAndWait(tester, find.byKey(const Key('bench-load')));
    expect(find.textContaining('2 models, 1 sample'), findsOneWidget);
    expect(find.textContaining('20261114_120000'), findsWidgets);

    await tapAndWait(tester, find.byKey(const Key('bench-run-matrix')));
    // 2 models x 3 compute-unit settings.
    expect(find.byKey(const Key('bench-arm')), findsNWidgets(6));
    expect(find.textContaining('1500 ms'), findsWidgets);
    expect(find.textContaining('3.0 s per photo'), findsWidgets);
    expect(find.textContaining('90% Neural Engine'), findsWidgets);
    expect(awake.enabled, 1);
    expect(awake.disabled, 1);

    await tapAndWait(tester, find.byKey(const Key('bench-share')));
    expect(shared, hasLength(1));
    final results = File(p.join(shared.single.path, 'bench_results.json'));
    expect(results.existsSync(), isTrue);
    final json = jsonDecode(results.readAsStringSync()) as Map<String, dynamic>;
    expect((json['arms'] as List), hasLength(6));
    expect(json['device'], 'iPhone14,7 test device');

    // A second matrix replaces the first rather than appending to it.
    await tapAndWait(tester, find.byKey(const Key('bench-run-matrix')));
    expect(find.byKey(const Key('bench-arm')), findsNWidgets(6));
  });

  testWidgets('the quick test runs one arm, and its folder can be shared again later', (tester) async {
    await pump(tester, zip: benchZip());
    await tapAndWait(tester, find.byKey(const Key('bench-load')));
    await tapAndWait(tester, find.byKey(const Key('bench-run-quick')));
    expect(find.byKey(const Key('bench-arm')), findsOneWidget);
    expect(find.textContaining('cs_512 · CPU + Neural Engine'), findsOneWidget);

    // As after a relaunch: a fresh screen lists the earlier folder and can share it.
    await tester.pumpWidget(const SizedBox());
    final shared = await pump(tester, zip: benchZip());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Has results'), findsOneWidget);
    await tester.tap(find.byTooltip('Share'));
    await tester.pump();
    expect(shared, hasLength(1));
  });

  testWidgets('a zip that is not a benchmark package shows why', (tester) async {
    await pump(tester, zip: benchZip(valid: false));
    await tapAndWait(tester, find.byKey(const Key('bench-load')));
    expect(find.textContaining('Not a ReefSight Core ML benchmark package'), findsOneWidget);
    expect(find.byKey(const Key('bench-run-matrix')), findsNothing);
  });
}
