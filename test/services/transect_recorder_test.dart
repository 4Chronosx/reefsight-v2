import 'dart:ui' show AppLifecycleState;

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

    // The fork's start/stop now throw instead of failing silently.
    test('a failed start leaves no output path and is not recording', () async {
      final recorder = TransectRecorder(
        startRecording: (_) async => throw StateError('camera view not attached yet'),
        stopRecording: () async {},
      );

      await expectLater(recorder.start('/documents'), throwsStateError);
      expect(recorder.isRecording, isFalse);
      expect(recorder.currentOutputPath, isNull);
    });

    test('a failed stop still ends the recording, so it is not retried forever', () async {
      var stopCalls = 0;
      final recorder = TransectRecorder(
        startRecording: (_) async {},
        stopRecording: () async {
          stopCalls++;
          throw StateError('recording_error');
        },
      );
      await recorder.start('/documents');

      await expectLater(recorder.stop(), throwsStateError);
      expect(recorder.isRecording, isFalse);
      await recorder.stop();
      expect(stopCalls, 1);
    });
  });

  // The Live screen waits for the camera view to attach before recording;
  // asking earlier was silently dropped, so no transect ever had a video.
  group('waitUntil', () {
    test('true as soon as the condition holds', () async {
      var ready = false;
      Future<void>.delayed(const Duration(milliseconds: 30), () => ready = true);
      expect(
        await waitUntil(() => ready, interval: const Duration(milliseconds: 5)),
        isTrue,
      );
    });

    test('false when it never holds within the timeout', () async {
      expect(
        await waitUntil(
          () => false,
          timeout: const Duration(milliseconds: 40),
          interval: const Duration(milliseconds: 5),
        ),
        isFalse,
      );
    });

    test('true immediately, without waiting, when already true', () async {
      final watch = Stopwatch()..start();
      expect(await waitUntil(() => true), isTrue);
      expect(watch.elapsedMilliseconds, lessThan(50));
    });
  });

  // iOS stops the camera whenever the app leaves the foreground, so a REC
  // timer still counting after that would be a lie.
  group('recordingInterruptedMessage', () {
    const elapsed = Duration(minutes: 12, seconds: 34);

    test('leaving the foreground while recording interrupts it', () {
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
        expect(
          recordingInterruptedMessage(state, recording: true, elapsed: elapsed),
          'Interrupted at 12:34 - nothing after this is recorded',
          reason: '',
        );
      }
    });

    test('inactive (Control Centre, a banner) keeps the camera running', () {
      expect(
        recordingInterruptedMessage(AppLifecycleState.inactive, recording: true, elapsed: elapsed),
        isNull,
      );
    });

    test('nothing to interrupt when not recording, or when resuming', () {
      expect(
        recordingInterruptedMessage(AppLifecycleState.paused, recording: false, elapsed: elapsed),
        isNull,
      );
      expect(
        recordingInterruptedMessage(AppLifecycleState.resumed, recording: true, elapsed: elapsed),
        isNull,
      );
    });
  });
}
