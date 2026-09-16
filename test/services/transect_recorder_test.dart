import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/transect_recorder.dart';

// Sub-plan 3 step 1: one continuous video file per transect. The actual
// native start/stop (Task 1's ultralytics_yolo fork) is injected as plain
// functions so this class's lifecycle logic is testable without a real
// platform channel / native camera session -- Task 4 wires the real fork in.

void main() {
  group('TransectRecorder', () {
    test('start() calls the injected startRecording with a path under the '
        'given directory', () async {
      String? capturedPath;
      final recorder = TransectRecorder(
        startRecording: (path) async => capturedPath = path,
        stopRecording: () async {},
      );

      final path = await recorder.start('/documents');

      expect(capturedPath, path);
      expect(path, startsWith('/documents/'));
      expect(path, endsWith('.mov'));
      expect(recorder.isRecording, isTrue);
    });

    test('start() uses a custom file name builder when provided', () async {
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async {},
        fileNameBuilder: () => 'fixed.mov',
      );

      final path = await recorder.start('/documents');

      expect(path, '/documents/fixed.mov');
    });

    test('calling start() twice without stop() is idempotent', () async {
      var startCalls = 0;
      final recorder = TransectRecorder(
        startRecording: (_) async => startCalls++,
        stopRecording: () async {},
      );

      final first = await recorder.start('/documents');
      final second = await recorder.start('/documents');

      expect(startCalls, 1);
      expect(second, first);
    });

    test('stop() calls the injected stopRecording and clears isRecording',
        () async {
      var stopCalls = 0;
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async => stopCalls++,
      );

      await recorder.start('/documents');
      await recorder.stop();

      expect(stopCalls, 1);
      expect(recorder.isRecording, isFalse);
    });

    test('stop() without a prior start() is a no-op', () async {
      var stopCalls = 0;
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async => stopCalls++,
      );

      await recorder.stop();

      expect(stopCalls, 0);
    });

    test('currentOutputPath survives stop() so callers can read the '
        'finished file location', () async {
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async {},
      );

      final path = await recorder.start('/documents');
      await recorder.stop();

      expect(recorder.currentOutputPath, path);
    });

    test('currentOutputPath is null before any start()', () {
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async {},
      );

      expect(recorder.currentOutputPath, isNull);
    });
  });
}
